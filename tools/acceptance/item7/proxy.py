import http.client, http.server, json, os, socket, struct, threading, time, base64, ctypes, ctypes.wintypes
from acceptance_control import FaultControl

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "local_config.json")
with open(CONFIG_PATH, "r", encoding="utf-8") as config_stream:
    CONFIG = json.load(config_stream)
UP_HOST, UP_PORT = CONFIG["upstreamHost"], int(CONFIG["upstreamPort"])
PORT_A, PORT_B = int(CONFIG["proxyPortA"]), int(CONFIG["proxyPortB"])
UP_USERNAME = CONFIG["username"]
RUNTIME = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "sp_accept")
os.makedirs(RUNTIME, exist_ok=True)
LOG = os.path.join(RUNTIME, "proxy_log.jsonl")
CONTROL = os.path.join(RUNTIME, "proxy_control.json")
STATUS = os.path.join(RUNTIME, "proxy_status.json")
PROFILE_ID = CONFIG["profileId"]
LOG_LOCK = threading.Lock()
FAULT_CONTROL = FaultControl(CONTROL, STATUS)


def cred_read_password():
    adv = ctypes.windll.advapi32

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [("Flags", ctypes.wintypes.DWORD), ("Type", ctypes.wintypes.DWORD),
                    ("TargetName", ctypes.c_wchar_p), ("Comment", ctypes.c_wchar_p),
                    ("LastWritten", ctypes.wintypes.FILETIME), ("CredentialBlobSize", ctypes.wintypes.DWORD),
                    ("CredentialBlob", ctypes.c_void_p), ("Persist", ctypes.wintypes.DWORD),
                    ("AttributeCount", ctypes.wintypes.DWORD), ("Attributes", ctypes.c_void_p),
                    ("TargetAlias", ctypes.c_wchar_p), ("UserName", ctypes.c_wchar_p)]

    cred_p = ctypes.c_void_p()
    target = ctypes.create_unicode_buffer("StreamPath/server-profile/" + PROFILE_ID)
    if not adv.CredReadW(target, 1, 0, ctypes.byref(cred_p)):
        return None
    cred = ctypes.cast(cred_p, ctypes.POINTER(CREDENTIAL)).contents
    blob = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
    adv.CredFree(cred_p)
    try:
        data = json.loads(blob.decode("utf-8"))
        return data.get("webDavPassword")
    except Exception:
        return None


PASSWORD = None


def auth_header():
    global PASSWORD
    if PASSWORD is None:
        PASSWORD = cred_read_password() or ""
    token = base64.b64encode((UP_USERNAME + ":" + PASSWORD).encode()).decode()
    return "Basic " + token


def log(**kw):
    kw["ts"] = round(time.time(), 4)
    with LOG_LOCK:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(kw, ensure_ascii=False) + "\n")


def force_rst(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    except Exception:
        pass
    try:
        sock.close()
    except Exception:
        pass


class RelayHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SPAccept/1"
    leg = "A"

    def log_message(self, *a):
        pass

    def _shift_cr(self, cr):
        try:
            head, total = cr.split("/")
            unit, rng = head.split(" ")
            a, b = rng.split("-")
            return "%s %d-%s/%s" % (unit, int(a) + 16, b, total)
        except Exception:
            return "bytes 999999999-999999999/21474836480"

    def _handle(self):
        fault = FAULT_CONTROL.snapshot()
        mode = fault["mode"]
        arm_id = fault["arm_id"]
        rng = self.headers.get("Range")
        is_media_range = rng is not None and "bytes=0-0" not in rng
        auth_state = "yes" if self.headers.get("Authorization") else "no"

        def request_info():
            return {"leg": self.leg, "method": self.command,
                    "path": self.path[:120], "range": (rng or "")[:60]}

        def claim_fault():
            return FAULT_CONTROL.claim(fault, request_info())

        if self.leg == "A" and mode in ("redirect", "final_403") and claim_fault():
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d%s" % (PORT_B, self.path))
            self.send_header("Content-Length", "0")
            self.end_headers()
            log(leg="A", mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=302,
                arm_id=arm_id, injected=True, note="redirected")
            return

        if mode == "force_416" and rng is not None and claim_fault():
            body = b"<?xml version=\"1.0\"?><error>range not satisfiable</error>"
            self.send_response(416)
            self.send_header("Content-Range", "bytes */123456789")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/xml")
            self.end_headers()
            self.wfile.write(body)
            log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=416,
                arm_id=arm_id, injected=True, note="injected-416")
            return

        if mode == "no_range" and rng is not None and claim_fault():
            self.send_response(200)
            self.send_header("Accept-Ranges", "none")
            self.send_header("Content-Length", "21474836480")
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            try:
                self.wfile.write(b"\x00" * 65536)
                self.wfile.flush()
            except Exception:
                pass
            force_rst(self.connection)
            self.close_connection = True
            log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=200,
                arm_id=arm_id, injected=True, note="injected-200-no-range,cut64k")
            return

        try:
            up = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=30)
            hdrs = {}
            for k, v in self.headers.items():
                if k.lower() in ("host", "authorization", "accept-encoding", "connection", "proxy-connection"):
                    continue
                hdrs[k] = v
            hdrs["Host"] = "%s:%d" % (UP_HOST, UP_PORT)
            hdrs["Accept-Encoding"] = "identity"
            hdrs["Authorization"] = auth_header()
            body = None
            cl = self.headers.get("Content-Length")
            if cl:
                body = self.rfile.read(int(cl))
            up.request(self.command, self.path, body=body, headers=hdrs)
            resp = up.getresponse()
            data_headers = dict(resp.getheaders())
            status = resp.status
        except Exception as e:
            log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state,
                arm_id=arm_id, injected=False, error=type(e).__name__, note="upstream-fail")
            try:
                self.send_error(502)
            except Exception:
                pass
            self.close_connection = True
            return

        header_injected = False
        injection_note = None
        if mode == "no_validator" and claim_fault():
            for key in list(data_headers):
                if key.lower() in ("etag", "last-modified"):
                    data_headers.pop(key, None)
            header_injected = True
            injection_note = "injected-no-validator"
        if mode == "bad_content_range" and rng is not None and status == 206 and claim_fault():
            data_headers["Content-Range"] = self._shift_cr(data_headers.get("Content-Range", ""))
            header_injected = True
            injection_note = "injected-bad-content-range"

        if mode == "remote_changed" and is_media_range and status == 206 and claim_fault():
            self.send_response(200)
            self.send_header("Content-Length", "21474836480")
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            try:
                self.wfile.write(b"\x11" * 4096)
                self.wfile.flush()
            except Exception:
                pass
            force_rst(self.connection)
            self.close_connection = True
            log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=200,
                arm_id=arm_id, injected=True, note="injected-remote-changed,cut4k")
            return

        if mode == "midstream_cut_body" and is_media_range and status == 206:
            if rng == "bytes=0-4194303":
                pass  # context/metadata read: pass through so localhost 206 headers succeed
            elif claim_fault():
                self.send_response(206)
                for k in ("Content-Range", "Content-Type", "ETag", "Last-Modified", "Accept-Ranges"):
                    if k in data_headers:
                        self.send_header(k, data_headers[k])
                clen = int(data_headers.get("Content-Length", "0"))
                self.send_header("Content-Length", str(clen))
                self.end_headers()
                sent = 0
                try:
                    while sent < clen:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        sent += len(chunk)
                        if sent >= 1048576:
                            break
                except Exception:
                    pass
                force_rst(self.connection)
                self.close_connection = True
                log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                    path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=206,
                    arm_id=arm_id, injected=True,
                    note="injected-body-cut-after-headers,sent=%d" % sent)
                return

        if mode == "midstream_cut" and is_media_range and status == 206 and claim_fault():
            self.send_response(206)
            for k in ("Content-Range", "Content-Type", "ETag", "Last-Modified", "Accept-Ranges"):
                if k in data_headers:
                    self.send_header(k, data_headers[k])
            clen = int(data_headers.get("Content-Length", "0"))
            self.send_header("Content-Length", str(clen))
            self.end_headers()
            sent = 0
            try:
                while sent < clen:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent += len(chunk)
                    if sent >= 1048576:
                        break
            except Exception:
                pass
            force_rst(self.connection)
            self.close_connection = True
            log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
                path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=206,
                arm_id=arm_id, injected=True, note="injected-midstream-cut,sent=%d" % sent)
            return

        self.send_response(status)
        chunked = "Transfer-Encoding" in data_headers
        no_cl = "Content-Length" not in data_headers
        body_buf = None
        if (chunked or no_cl) and self.command != "HEAD" and status not in (204, 304):
            parts = []
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    parts.append(chunk)
            except Exception:
                pass
            body_buf = b"".join(parts)
        for k, v in data_headers.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length", "date", "server"):
                self.send_header(k, v)
        if body_buf is not None:
            self.send_header("Content-Length", str(len(body_buf)))
        elif "Content-Length" in data_headers:
            self.send_header("Content-Length", data_headers["Content-Length"])
        elif "Content-Length" not in data_headers and status not in (204, 304):
            self.send_header("Content-Length", "0")
        self.end_headers()
        if body_buf is not None:
            try:
                self.wfile.write(body_buf)
            except Exception:
                self.close_connection = True
        elif self.command != "HEAD" and status not in (204, 304):
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except Exception:
                self.close_connection = True
        try:
            up.close()
        except Exception:
            pass
        log(leg=self.leg, mode=mode, client_port=self.client_address[1], method=self.command,
            path=self.path[:120], range=(rng or "")[:60], auth=auth_state, status=status,
            arm_id=arm_id, injected=header_injected, note=injection_note,
            cr=(data_headers.get("Content-Range", "")[:60]),
            etag=("ETag" in data_headers), lm=("Last-Modified" in data_headers),
            clen=(data_headers.get("Content-Length", "")[:20]))

    do_GET = do_HEAD = do_POST = do_PUT = do_OPTIONS = do_PROPFIND = do_PROPPATCH = do_MKCOL = do_COPY = do_MOVE = do_DELETE = do_LOCK = do_UNLOCK = _handle


class LegA(RelayHandler):
    leg = "A"


class LegB(RelayHandler):
    leg = "B"


def serve(cls, port):
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), cls)
    httpd.daemon_threads = True
    httpd.serve_forever()


if __name__ == "__main__":
    threading.Thread(target=FAULT_CONTROL.watch, daemon=True).start()
    threading.Thread(target=serve, args=(LegA, PORT_A), daemon=True).start()
    threading.Thread(target=serve, args=(LegB, PORT_B), daemon=True).start()
    print("proxy ready A=%d B=%d" % (PORT_A, PORT_B), flush=True)
    while True:
        time.sleep(3600)
