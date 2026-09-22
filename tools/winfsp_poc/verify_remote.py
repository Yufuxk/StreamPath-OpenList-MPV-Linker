"""Test the real helper over a local Range server; never uses WebDAV credentials."""
import argparse
import ctypes
from ctypes import wintypes
import http.server
import json
import pathlib
import struct
import subprocess
import threading
import time


def run(args):
    root = pathlib.Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    session = root / "session"
    session.mkdir()
    # Preserve the source and use IMAPI's read-only composite stream as fixture.
    fixture = subprocess.Popen([args.poc, str(root / "source"), args.bdmv, str(args.timeout + 60)],
                               creationflags=subprocess.CREATE_NO_WINDOW,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    helper = player = server = pipe = None
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                               ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    kernel.WriteFile.argtypes = kernel.ReadFile.argtypes
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]

    def read_exact(count):
        result = b""
        while len(result) < count:
            data = ctypes.create_string_buffer(count - len(result))
            received = wintypes.DWORD()
            if not kernel.ReadFile(pipe, data, len(data), ctypes.byref(received), None) or not received.value:
                raise RuntimeError("Helper pipe read failed")
            result += data.raw[:received.value]
        return result

    def receive():
        length, = struct.unpack("<I", read_exact(4))
        if length > 1048576:
            raise RuntimeError("Oversized helper frame")
        return json.loads(read_exact(length))

    def send(message):
        data = json.dumps(message).encode()
        frame = struct.pack("<I", len(data)) + data
        written = wintypes.DWORD()
        if not kernel.WriteFile(pipe, frame, len(frame), ctypes.byref(written), None) or written.value != len(frame):
            raise RuntimeError("Helper pipe write failed")

    try:
        source = root / "source" / "disc.iso"
        for _ in range(200):
            if source.exists():
                break
            if fixture.poll() is not None:
                raise RuntimeError(fixture.communicate()[1].decode(errors="replace"))
            time.sleep(.05)
        total = source.stat().st_size
        counters = {"requests": 0, "bytes": 0}
        bandwidth_lock = threading.Lock()
        bandwidth_ready = time.monotonic()
        playback_started = None
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_HEAD(self):
                self.send_response(200)
                self.send_header("Content-Length", str(total))
                self.send_header("ETag", '"fixture-v1"')
                self.end_headers()

            def do_GET(self):
                nonlocal bandwidth_ready
                header = self.headers.get("Range", "")
                if not header.startswith("bytes="):
                    self.send_error(400)
                    return
                start, end = map(int, header[6:].split("-"))
                if not 0 <= start <= end < total:
                    self.send_error(416)
                    return
                if args.delay_ms:
                    time.sleep(args.delay_ms / 1000)
                counters["requests"] += 1
                self.send_response(206)
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                self.send_header("ETag", '"fixture-v1"')
                try:
                    self.end_headers()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    return
                with source.open("rb", buffering=0) as image:
                    image.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        if playback_started is not None and args.outage_seconds:
                            elapsed = time.monotonic() - playback_started
                            phase = elapsed % args.outage_period
                            if elapsed >= args.outage_period and phase < args.outage_seconds:
                                time.sleep(args.outage_seconds - phase)
                        data = image.read(min(262144, remaining))
                        if not data:
                            raise IOError("Short fixture read")
                        if args.body_mibps:
                            with bandwidth_lock:
                                bandwidth_ready = max(time.monotonic(), bandwidth_ready) + len(data) / (args.body_mibps * 1048576)
                                send_at = bandwidth_ready
                            time.sleep(max(0, send_at - time.monotonic()))
                        try:
                            self.wfile.write(data)
                        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                            return
                        counters["bytes"] += len(data)
                        remaining -= len(data)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        helper_path = pathlib.Path(args.helper).resolve()
        suffix = "streampath_poc_" + str(time.time_ns())
        helper = subprocess.Popen([str(helper_path), "--pipe=" + suffix,
                                   "--parent-pid=" + str(__import__("os").getpid())],
                                  creationflags=subprocess.CREATE_NO_WINDOW)
        for _ in range(200):
            pipe = kernel.CreateFileW("\\\\.\\pipe\\" + suffix, 0xC0000000, 0, None, 3, 0, None)
            if pipe != ctypes.c_void_p(-1).value:
                break
            pipe = None
            time.sleep(.05)
        if pipe is None:
            raise RuntimeError("Helper pipe did not appear")
        hello = receive()
        assert hello["pid"] == helper.pid
        url = f"http://127.0.0.1:{server.server_port}/disc.iso"
        send({"type": "open_disc", "mode": "hdmv", "transport": "winfsp", "version": 1,
              "url": url, "origin": url.rsplit("/", 1)[0], "username": "", "password": "",
              "sessionPath": str(session), "structureCachePath": str(root / "iso_structure" / ("a" * 64 + ".cache"))})
        while True:
            ready = receive()
            if ready.get("type") != "metrics":
                break
        if ready.get("capability") != "winfsp-disc-v1":
            raise RuntimeError("Helper rejected fixture: " + json.dumps(ready))
        assert ready["discPath"] == str(session / "disc" / "disc.iso")
        configuration = {"type": "configure_cache", "blockCount": args.cache_blocks, "prefetchBlocks": args.prefetch_blocks}
        if args.cache_secs is not None:
            configuration['cacheSecs'] = args.cache_secs
        send(configuration)
        assert receive().get("configured") is True
        with (root / "mpv.log").open("wb") as log:
            extra = []
            if args.cache_panel_script:
                panel = session / "sp-menu-cache.lua"
                header, body = pathlib.Path(args.cache_panel_script).read_text(encoding="utf-8").split("\n", 1)
                config = json.loads(json.loads(header.split(" = ", 1)[1]))
                config["metrics"] = str(session / "iso-bridge-metrics.json")
                panel.write_text("local CONFIG_JSON = " + json.dumps(json.dumps(config, ensure_ascii=False), ensure_ascii=False)
                                 + "\n" + body, encoding="utf-8")
                extra.append("--script=" + str(panel))
            playback_started = time.monotonic()
            player = subprocess.Popen([args.mpv, "--no-config",
                "--vo=gpu-next" if args.visible else "--vo=null", "--ao=null", *extra,
                "--idle=no", "--keep-open=no", "--cache=yes", "--cache-on-disk=no",
                "--demuxer-max-bytes=" + str(args.mpv_cache_bytes), "--demuxer-max-back-bytes=0",
                "--script=" + str(pathlib.Path(args.probe_script).resolve()),
                "--script-opts=probe-output=" + str(root / "menu.json") + ",probe-duration=" + str(args.probe_duration),
                "--bluray-device=" + ready["discPath"], "bd://menu"],
                creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=log)
            send({"type": "attachPlayer", "pid": player.pid})
            assert receive().get("attached") is True
            kernel.CloseHandle(pipe)
            pipe = None
            assert player.wait(timeout=args.timeout) == 0
        assert helper.wait(timeout=15) == 0
        assert not (session / "disc").exists(), "Helper left its mount behind"
        menu = json.loads((root / "menu.json").read_text())
        metrics = json.loads((session / "iso-bridge-metrics.json").read_text())
        summary = {"sourceBytes": total, "server": counters,
                   "menuObserved": any(s.get("menu") is True for s in menu["samples"]),
                   "playbackRestarts": [s["ms"] for s in menu["samples"] if s["event"] == "playback-restart"],
                   "final": metrics["bridge"]["final"], "headless": not args.visible, "delayMs": args.delay_ms,
                   "bodyMiBps": args.body_mibps,
                   "cacheBlocks": args.cache_blocks, "prefetchBlocks": args.prefetch_blocks,
                   "cacheSecs": args.cache_secs, "outageSeconds": args.outage_seconds,
                   "outagePeriod": args.outage_period}
        (root / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary))
        assert summary["final"], "Final snapshot missing"
        assert not metrics["virtualDisc"]["failed"], "Virtual disc reported a read failure"
        if menu['schema'] == 1:
            assert summary['menuObserved'], 'Menu missing'
            commands = [s for s in menu["samples"] if s["event"] == "command-result"]
            assert len(commands) == 7 and not any(s["detail"].get("error") for s in commands), "Menu command failed"
        else:
            assert menu['schema'] == 2 and menu['measuredSeconds'] >= args.probe_duration - 1
            print(json.dumps({k: v for k, v in menu.items() if k != 'samples'}))
    finally:
        if pipe:
            kernel.CloseHandle(pipe)
        for process in (player, helper):
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        if server:
            server.shutdown()
            server.server_close()
        (root / "stop-poc").touch()
        try:
            fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.terminate()
            fixture.wait(timeout=10)
        out, err = fixture.communicate()
        (root / "fixture.log").write_bytes(out + err)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for field in ("poc", "helper", "bdmv", "mpv", "output"):
        parser.add_argument("--" + field, required=True)
    parser.add_argument("--delay-ms", type=int, default=0)
    parser.add_argument("--cache-blocks", type=int, default=4)
    parser.add_argument("--prefetch-blocks", type=int, default=4)
    parser.add_argument("--cache-secs", type=int)
    parser.add_argument("--outage-seconds", type=float, default=0)
    parser.add_argument("--outage-period", type=float, default=40)
    parser.add_argument("--mpv-cache-bytes", type=int, default=50331648)
    parser.add_argument("--body-mibps", type=float, default=0)
    parser.add_argument("--probe-script", default=str(pathlib.Path(__file__).with_name('menu_probe.lua')))
    parser.add_argument("--cache-panel-script")
    parser.add_argument("--visible", action="store_true")
    parser.add_argument("--probe-duration", type=int, default=90)
    parser.add_argument("--timeout", type=int, default=70)
    args = parser.parse_args()
    if args.body_mibps < 0 or args.outage_seconds < 0 or args.outage_period <= args.outage_seconds:
        parser.error('Bandwidth and outage must be non-negative; period must exceed outage')
    if args.probe_duration <= 0 or args.timeout <= 0:
        parser.error('Probe duration and timeout must be positive')
    run(args)
