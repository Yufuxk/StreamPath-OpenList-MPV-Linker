"""Validate the production DVD Bridge against a read-only ISO and real MPV builds."""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
import socket
from pathlib import Path
import struct
import subprocess
import time
import urllib.request
import uuid
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class IsoServer:
    def __init__(self, path, prefix=None):
        self.path = Path(path)
        self.version = 'dvd-test-v1'
        self.bytes = 0
        self.prefix = prefix
        self.disconnect = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def handle(self):
                try:
                    super().handle()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass

            def do_HEAD(self):
                self.serve(True)

            def do_GET(self):
                self.serve(False)

            def serve(self, head):
                size = owner.path.stat().st_size
                start, end = 0, size - 1
                value = self.headers.get('Range')
                if value:
                    a, b = value.removeprefix('bytes=').split('-')
                    start, end = int(a), min(int(b) if b else size - 1, size - 1)
                valid = self.headers.get('If-Range') in (None, '"' + owner.version + '"')
                self.send_response(206 if value and valid else 200)
                if value and valid:
                    self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                self.send_header('Content-Length', str(end - start + 1))
                self.send_header('ETag', '"' + owner.version + '"')
                self.end_headers()
                if head:
                    return
                if owner.disconnect:
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.close_connection = True
                    return
                try:
                    with owner.path.open('rb') as source:
                        source.seek(start)
                        remaining = end - start + 1
                        position = start
                        while remaining:
                            data = source.read(min(65536, remaining))
                            if not data:
                                break
                            if owner.prefix is not None and position < len(owner.prefix):
                                count = min(len(data), len(owner.prefix) - position)
                                data = owner.prefix[position:position+count] + data[count:]
                            self.wfile.write(data)
                            owner.bytes += len(data)
                            remaining -= len(data)
                            position += len(data)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/disc.iso'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class Bridge:
    def __init__(self, helper, iso, output, remote_url=None):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.session = self.output / ('session-' + uuid.uuid4().hex)
        self.session.mkdir()
        self.error_log = (self.session / 'helper.log').open('wb')
        pipe = 'streampath_dvd_test_' + uuid.uuid4().hex
        self.process = subprocess.Popen(
            [str(Path(helper).resolve()), '--pipe=' + pipe, '--parent-pid=' + str(os.getpid())],
            stdout=subprocess.DEVNULL, stderr=self.error_log,
            creationflags=subprocess.CREATE_NO_WINDOW)
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                          ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.kernel.CreateFileW.restype = wintypes.HANDLE
        self.kernel.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                        ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        self.kernel.WriteFile.argtypes = self.kernel.ReadFile.argtypes
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        deadline = time.monotonic() + 10
        while True:
            self.pipe = self.kernel.CreateFileW('\\\\.\\pipe\\' + pipe, 0xc0000000, 0, None, 3, 0, None)
            if self.pipe != ctypes.c_void_p(-1).value:
                break
            if time.monotonic() >= deadline:
                self.process.terminate()
                raise TimeoutError('Bridge control pipe did not open')
            time.sleep(.03)
        self.receive()
        request = dict(type='open', version=1, url=remote_url or 'http://127.0.0.1:1/disc.iso',
                       origin=remote_url or 'http://127.0.0.1:1/', username='', password='',
                       sessionPath=str(self.session),
                       structureCachePath=str(self.output / 'iso_structure' / (hashlib.sha256(str(iso).encode()).hexdigest() + '.cache')))
        if remote_url is None:
            request['localPath'] = str(Path(iso).resolve())
        self.send(request)
        while True:
            self.ready = self.receive()
            if self.ready['type'] != 'metrics':
                break
        if self.ready['type'] != 'ready':
            self.kernel.CloseHandle(self.pipe)
            self.process.wait(timeout=15)
            self.error_log.close()
            raise RuntimeError(self.ready)

    def read(self, count):
        result = b''
        while len(result) < count:
            data = ctypes.create_string_buffer(count - len(result))
            copied = wintypes.DWORD()
            if not self.kernel.ReadFile(self.pipe, data, len(data), ctypes.byref(copied), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if not copied.value:
                raise EOFError('Bridge control pipe closed')
            result += data.raw[:copied.value]
        return result

    def receive(self):
        return json.loads(self.read(struct.unpack('<I', self.read(4))[0]))

    def send(self, message):
        data = json.dumps(message).encode()
        framed = struct.pack('<I', len(data)) + data
        written = wintypes.DWORD()
        if not self.kernel.WriteFile(self.pipe, framed, len(framed), ctypes.byref(written), None):
            raise ctypes.WinError(ctypes.get_last_error())

    def url(self, title):
        number = int(title['programmeId'].removeprefix('dvd-title-'))
        return f"http://127.0.0.1:{self.ready['port']}/{self.ready['token']}/dvd/title/{number:05}.vob"

    def close(self):
        self.send(dict(type='shutdown'))
        self.kernel.CloseHandle(self.pipe)
        self.process.wait(timeout=15)
        self.error_log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('iso')
    parser.add_argument('--helper', default='build/dvd-support/native/streampath_iso_bridge.exe')
    parser.add_argument('--output', default='build/dvd-support/real')
    parser.add_argument('--mpv-root')
    parser.add_argument('--network', action='store_true')
    parser.add_argument('--title-number', type=int)
    args = parser.parse_args()
    started = time.monotonic()
    server = IsoServer(args.iso) if args.network else None
    bridge = Bridge(args.helper, args.iso, args.output, server.url if server else None)
    try:
        summary = dict(discType=bridge.ready['discType'], titles=bridge.ready['titles'],
                       prepareSeconds=time.monotonic() - started)
        (bridge.output / 'catalog.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
        print(json.dumps(summary), flush=True)
        title = (next(t for t in bridge.ready['titles'] if int(t['programmeId'][-2:]) == args.title_number)
                 if args.title_number else max(bridge.ready['titles'], key=lambda t: t['durationMs']))
        url = bridge.url(title)
        size = min(title['size'], 8 * 1024 * 1024)
        request = urllib.request.Request(url, headers={'Range': f'bytes=0-{size-1}'})
        data = urllib.request.urlopen(request, timeout=30).read()
        assert len(data) == size
        (bridge.output / 'first-title.vob').write_bytes(data)
        for start, length in [(1, 4095), (2047, 4099), (12345, 3219), (size-1001, 1000)]:
            requested = urllib.request.urlopen(urllib.request.Request(url, headers={'Range': f'bytes={start}-{start+length-1}'}), timeout=30).read()
            assert requested == data[start:start+length], (start, length)
        print('Range identity checks passed', flush=True)
        for start in [2147483648, title['size'] - 250000]:
            if start < title['size']:
                response = urllib.request.urlopen(urllib.request.Request(url,
                    headers={'Range': f'bytes={start}-{min(start+65535,title["size"]-1)}'}), timeout=30).read()
                assert len(response) == min(65536, title['size'] - start)
        print('Large-offset and tail reads passed', flush=True)
        if args.mpv_root:
            matrix = []
            for player in sorted(Path(args.mpv_root).rglob('mpv.exe')):
                cases = []
                for seek in [0, round(title['durationMs'] / 5000, 3), round(title['durationMs'] * .00096, 3)]:
                    result = subprocess.run([str(player.resolve()), '--no-config', '--vo=null', '--ao=null',
                        '--speed=10', '--start=' + str(seek), '--length=2', '--idle=no', '--keep-open=no',
                        url], capture_output=True, timeout=45,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    log = result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace')
                    (bridge.output / (player.parent.name + '-' + str(seek) + '.log')).write_text(log, encoding='utf-8')
                    success = result.returncode == 0 and 'VO:' in log and 'AO:' in log and not any(fatal in log for fatal in ['Failed to open', 'No video or audio streams', 'Exiting... (Errors'])
                    cases.append(dict(seek=seek, exitCode=result.returncode, passed=success, audioDecodeWarnings=log.count('Error decoding audio.')))
                matrix.append(dict(player=player.parent.name, cases=cases))
                print(json.dumps(matrix[-1]), flush=True)
            (bridge.output / 'mpv-matrix.json').write_text(json.dumps(matrix, indent=2), encoding='utf-8')
            assert all(case['passed'] for item in matrix for case in item['cases']), 'MPV matrix failed'
    finally:
        bridge.close()
        if server:
            cold_bytes = server.bytes
            warm = Bridge(args.helper, args.iso, args.output, server.url)
            warm_bytes = server.bytes - cold_bytes
            server.version = 'dvd-test-v2'
            changed_rejected = False
            try:
                urllib.request.urlopen(urllib.request.Request(warm.url(next(t for t in warm.ready['titles'] if t['programmeId'] == title['programmeId'])),
                    headers={'Range': 'bytes=2147483648-2147549183'}), timeout=10).read()
            except (urllib.error.HTTPError, ConnectionResetError):
                changed_rejected = True
            warm.close()
            metrics = json.loads((warm.session / 'iso-bridge-metrics.json').read_text())
            result = dict(coldNetworkBytes=cold_bytes, warmMetadataBytes=warm_bytes,
                          structureCacheHit=metrics['bluray']['structureCacheHit'], changedRejected=changed_rejected, lastErrorCode=metrics['lastErrorCode'])
            (bridge.output / 'network-cache.json').write_text(json.dumps(result, indent=2))
            print(json.dumps(result), flush=True)
            assert changed_rejected and metrics['lastErrorCode'] == 'remote_changed'
            interrupted = None
            try:
                server.version = 'dvd-test-v3'
                interrupted = Bridge(args.helper, args.iso, bridge.output / 'interrupted', server.url)
                server.disconnect = True
                target = next(t for t in interrupted.ready['titles'] if t['programmeId'] == title['programmeId'])
                start = min(2147483648, target['size']//2)
                try:
                    urllib.request.urlopen(urllib.request.Request(interrupted.url(target),
                        headers={'Range': f'bytes={start}-{min(start+65535,target["size"]-1)}'}), timeout=10).read()
                    raise AssertionError('Truncated source read was accepted')
                except (urllib.error.HTTPError, ConnectionResetError):
                    pass
                interrupted.close()
                interrupted_metrics = json.loads((interrupted.session / 'iso-bridge-metrics.json').read_text())
                assert interrupted_metrics['lastErrorCode'] == 'network_error', interrupted_metrics.get('lastErrorCode')
                (bridge.output / 'network-interruption.json').write_text(json.dumps(dict(rejected=True, lastErrorCode=interrupted_metrics['lastErrorCode'])))
                interrupted = None
            finally:
                if interrupted and interrupted.process.poll() is None:
                    interrupted.close()
                server.close()


if __name__ == '__main__':
    main()
