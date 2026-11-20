"""Compare mpv HTTP startup, seeks and bounded loopback readers against real files."""

import argparse
from collections import OrderedDict
from contextlib import closing, contextmanager
import ctypes
from ctypes import wintypes
import http.client
import http.server
import json
import math
from pathlib import Path
import random
import re
import secrets
import socket
import statistics
import subprocess
import threading
import time
from urllib.parse import urlsplit

from ts_startup_benchmark import RangeHandler, RangeServer, memory_peak, observer_source

BASELINE_VARIANTS = ['probe', 'smart', 'native', 'light', 'no-initial']
PROXY_VARIANTS = ['proxy', 'proxy-native', 'proxy-light', 'prefetch-4096']
BLOCK_VARIANTS = [f'block-{size}' for size in (256, 512, 1024, 2048, 4096)]


class OriginHandler(RangeHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        with self.server.lock:
            self.server.connections_seen += 1

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError):
            pass

    def end_headers(self):
        etag = getattr(self.server, 'etag', '"fixture"')
        if etag is not None:
            self.send_header('ETag', etag)
        super().end_headers()

    def do_GET(self):
        fault = getattr(self.server, 'fault', None)
        if fault == 'no-range' and 'Range' in self.headers:
            del self.headers['Range']
        if fault == 'unavailable':
            self.send_error(503)
            return
        if fault == 'drop-once':
            self.server.fault = None
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return
        super().do_GET()

    def send_header(self, name, value):
        if name == 'Content-Range' and getattr(self.server, 'fault', None) == 'invalid-range':
            value = 'bytes 0-0/1'
        super().send_header(name, value)


@contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, args=(.05,), daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def fixture_origin(files, latency_ms=0, mbps=0, redirect=False):
    origin = RangeServer(files, latency_ms, mbps, redirect)
    origin.connections_seen = 0
    origin.RequestHandlerClass = OriginHandler
    return origin


class Loopback(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, upstream, size, block, prefetch=False):
        super().__init__(('127.0.0.1', 0), LoopbackHandler)
        self.upstream = urlsplit(upstream)
        self.size = size
        self.path = '/' + secrets.token_urlsafe(24) + Path(self.upstream.path).suffix
        self.block = block
        self.prefetch = prefetch
        self.cache = OrderedDict()
        self.locks = [threading.Lock() for _ in range(4)]
        self.cache_lock = threading.Lock()
        self.connections = threading.local()
        self.cache_hits = 0
        self.cache_peak = 0
        self.connections_open = set()
        self.transfers = threading.BoundedSemaphore(4)
        self.tail_slot = threading.Semaphore()

    def server_close(self):
        with self.cache_lock:
            for connection in self.connections_open:
                connection.close()
        super().server_close()

    def fetch(self, start, end):
        connection = getattr(self.connections, 'http', None)
        if connection is None:
            connection = self.connections.http = http.client.HTTPConnection(
                self.upstream.hostname, self.upstream.port, timeout=8)
            with self.cache_lock:
                self.connections_open.add(connection)
        target = self.upstream.path
        for _ in range(2):
            connection.request('GET', target, headers={
                'Range': f'bytes={start}-{end}', 'If-Range': '"fixture"'})
            response = connection.getresponse()
            if response.status != 302:
                break
            target = response.getheader('Location')
            if target is None or not target.startswith('/media.'):
                connection.close()
                raise ValueError('Unexpected fixture redirect')
            response.read()
        if (response.status != 206 or response.getheader('ETag') != '"fixture"'
                or response.getheader('Content-Range') != f'bytes {start}-{end}/{self.size}'
                or response.getheader('Content-Length') != str(end - start + 1)):
            connection.close()
            raise ValueError('Invalid upstream range')
        return response

    def read_block(self, offset):
        with self.locks[(offset // self.block) % len(self.locks)]:
            with self.cache_lock:
                data = self.cache.get(offset)
                if data is not None:
                    self.cache_hits += 1
                    self.cache.move_to_end(offset)
                    return data
            end = min(self.size, offset + self.block) - 1
            try:
                data = self.fetch(offset, end).read()
            except (OSError, http.client.RemoteDisconnected, http.client.IncompleteRead):
                self.connections.http.close()
                data = self.fetch(offset, end).read()
            with self.cache_lock:
                while len(self.cache) >= (16 * 1024**2) // self.block:
                    self.cache.popitem(last=False)
                self.cache[offset] = data
                self.cache_peak = max(self.cache_peak, len(self.cache) * self.block)
            return data


class LoopbackHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        server = self.server
        if self.path != server.path:
            self.send_error(404)
            return
        if not server.transfers.acquire(blocking=False):
            self.send_error(503)
            return
        try:
            self.transfer(body)
        except (OSError, http.client.HTTPException, ValueError):
            self.close_connection = True
        finally:
            connection = getattr(server.connections, 'http', None)
            if connection is not None:
                connection.close()
                with server.cache_lock:
                    server.connections_open.discard(connection)
                del server.connections.http
            server.transfers.release()

    def transfer(self, body):
        server = self.server
        start, end = 0, server.size - 1
        requested = self.headers.get('Range')
        if requested and self.headers.get('If-Range', '"fixture"') != '"fixture"':
            requested = None
        if requested:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
            if match and match[1]:
                start = int(match[1])
                if match[2]:
                    end = min(end, int(match[2]))
            elif match and match[2] and int(match[2]) > 0:
                start = max(0, server.size - int(match[2]))
            else:
                start = server.size
            if start > end:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{server.size}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
        upstream = server.fetch(start, end) if body and not server.block else None
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"fixture"')
        self.send_header('Content-Length', str(end - start + 1))
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{server.size}')
        self.end_headers()
        if upstream:
            while start <= end:
                data = upstream.read1(min(65536, end - start + 1))
                if not data:
                    raise http.client.IncompleteRead(b'', end - start + 1)
                self.wfile.write(data)
                start += len(data)
        elif body:
            if server.prefetch and start == 0 and server.tail_slot.acquire(blocking=False):
                offset = (server.size - 1) // server.block * server.block
                threading.Thread(target=self.prefetch, args=(offset,), daemon=True).start()
            while start <= end:
                offset = start // server.block * server.block
                data = memoryview(server.read_block(offset))
                consumed = min(len(data), end - offset + 1)
                self.wfile.write(data[start - offset:consumed])
                start = offset + consumed

    def prefetch(self, offset):
        server = self.server
        try:
            server.read_block(offset)
        except (OSError, http.client.HTTPException, ValueError):
            pass
        finally:
            connection = getattr(server.connections, 'http', None)
            if connection is not None:
                connection.close()
                with server.cache_lock:
                    server.connections_open.discard(connection)
            server.tail_slot.release()


class DisplaySample:
    """Measure the first MPV video marker captured from the visible Windows desktop."""

    def __init__(self, process, began):
        self.ready_ms = None
        self.interval_ms = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.capture, args=(process.pid, began))
        self.thread.start()

    def finish(self):
        self.stop.set()
        self.thread.join()

    def capture(self, pid, began):
        user = ctypes.windll.user32
        gdi = ctypes.windll.gdi32
        user.GetDC.argtypes = [wintypes.HWND]
        user.GetDC.restype = wintypes.HDC
        user.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
        user.WindowFromPoint.argtypes = [wintypes.POINT]
        user.WindowFromPoint.restype = wintypes.HWND
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        user.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
        user.IsWindowVisible.argtypes = [wintypes.HWND]
        gdi.GetPixel.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
        gdi.GetPixel.restype = wintypes.DWORD
        hwnd = None
        prev = None

        @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def find(window, _):
            nonlocal hwnd
            owner = wintypes.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(owner))
            if owner.value == pid and user.IsWindowVisible(window):
                hwnd = window
                return False
            return True

        dc = user.GetDC(None)
        if not dc:
            return
        try:
            while not self.stop.wait(.008):
                if hwnd is None:
                    user.EnumWindows(find, 0)
                rect = wintypes.RECT()
                if not hwnd or not user.GetClientRect(hwnd, ctypes.byref(rect)):
                    continue
                point = wintypes.POINT(rect.right // 2, rect.bottom // 2)
                if not user.ClientToScreen(hwnd, ctypes.byref(point)) or user.WindowFromPoint(point) != hwnd:
                    continue
                pixel = gdi.GetPixel(dc, point.x, point.y)
                now = (time.perf_counter() - began) * 1000
                if pixel != 0xffffffff and pixel & 255 > 210 and (pixel >> 8) & 255 < 60 and (pixel >> 16) & 255 > 210:
                    self.ready_ms = now
                    self.interval_ms = None if prev is None else now - prev
                    return
                prev = now
        finally:
            user.ReleaseDC(None, dc)


def process_usage(process):
    if not hasattr(ctypes, 'windll'):
        return {}
    kernel = ctypes.windll.kernel32
    get_times = kernel.GetProcessTimes
    get_times.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    times = [wintypes.FILETIME() for _ in range(4)]
    result = {}
    if get_times(int(process._handle), *(ctypes.byref(t) for t in times)):
        result['mpvCpuMs'] = sum((t.dwHighDateTime << 32) + t.dwLowDateTime
                                 for t in times[2:]) / 10000
    return result


def playback(mpv, target, observer, variant, size, timeout, vo, is_ts, display):
    # 使用同一组 MPV 参数隔离网络读法。smart 参数为有界代表值。
    options = ['--cache=yes', '--cache-secs=30', '--demuxer-max-bytes=128MiB',
               '--cache-pause=yes', '--cache-pause-initial=yes',
               '--cache-pause-wait=5' if is_ts else '--cache-pause-wait=3']
    if is_ts:
        options.append('--demuxer-seekable-cache=no')
    if variant in ('native', 'proxy-native'):
        options = []
    if variant in ('light', 'proxy-light'):
        options = ['--cache=yes', '--cache-secs=10', '--demuxer-max-bytes=32MiB']
    if variant == 'no-initial':
        options.append('--cache-pause-initial=no')
    if display:
        options += ['--ontop', '--autofit=480x300', '--geometry=-30-60',
                    '--vf=lavfi=[drawbox=x=iw/2-32:y=ih/2-32:w=64:h=64:color=magenta:t=fill]']
    began = time.perf_counter()
    probe_ms = 0
    if variant == 'probe':
        upstream = urlsplit(target)
        path = upstream.path
        with closing(http.client.HTTPConnection(upstream.hostname, upstream.port,
                                                timeout=1.5)) as connection:
            for _ in range(2):
                connection.request('HEAD', path)
                response = connection.getresponse()
                if response.status != 302:
                    break
                path = response.getheader('Location')
                response.read()
            assert response.status == 200
            assert int(response.headers['Content-Length']) == size
        probe_ms = (time.perf_counter() - began) * 1000
    before_process = time.perf_counter()
    cmd = [str(mpv), '--no-config', '--load-scripts=no', '--no-resume-playback',
           '--rebase-start-time=yes', '--ao=null', '--osd-level=0',
           f'--vo={vo}', '--hwdec=auto-copy' if display else '--hwdec=no',
           '--script=' + str(observer), *options, target]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               encoding='utf-8', errors='replace',
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    created = time.perf_counter()
    capture = DisplaySample(process, began) if display else None
    events = []
    output = []
    deadline = threading.Timer(timeout, process.kill)
    deadline.start()
    peak = 0
    try:
        for line in process.stdout:
            if 'SP_STARTUP ' in line:
                event = json.loads(line.split('SP_STARTUP ', 1)[1])
                event['receivedMs'] = (time.perf_counter() - began) * 1000
                events.append(event)
                peak = max(peak, memory_peak(process) or 0)
            elif line.strip():
                output.append(line.strip())
        process.wait()
    finally:
        if capture:
            capture.finish()
        deadline.cancel()
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    seek = [e['receivedMs'] for e in events if e['event'] == 'seekRequested']
    restarts = [e['receivedMs'] for e in events if e['event'] == 'mpvPlaybackRestart']
    cutoff = began + restarts[0] / 1000 if restarts else None
    return {
        **process_usage(process),
        'code': process.returncode, 'probeMs': probe_ms, 'memoryBytes': peak,
        'processMs': (created - before_process) * 1000, 'events': events,
        'restartMs': restarts[0] if restarts else None,
        'firstVisibleMs': capture.ready_ms if capture else None,
        'displaySampleIntervalMs': capture.interval_ms if capture else None,
        'seekMs': [end - start for start, end in zip(seek, restarts[1:])],
        'startupCutoff': cutoff, 'outputTail': output[-4:] if process.returncode else [],
    }


def make_observer(seconds):
    return observer_source() + f"""
local seek_targets = {{0.62, 0.31, 0.62}}
local issued = 0
mp.register_event('playback-restart', function()
    mp.add_timeout(issued == 0 and {seconds} or 1, function()
        if issued >= #seek_targets then mp.commandv('quit'); return end
        issued = issued + 1
        snapshot('seekRequested')
        mp.commandv('seek', seek_targets[issued] * 100, 'absolute-percent+keyframes')
    end)
end)
"""


def run(args, media, variant, observer):
    size = media.stat().st_size
    suffix = media.suffix.lower()
    path = '/entry' if args.redirect else '/media'
    with running(fixture_origin({'/media' + suffix: media}, args.latency_ms,
                                args.mbps, args.redirect)) as origin:
        origin.fault = args.origin_fault
        url = f'http://127.0.0.1:{origin.server_port}{path}{suffix}'
        if variant.startswith(('proxy', 'block', 'prefetch')):
            block = int(variant.split('-')[-1]) * 1024 if variant.startswith(
                ('block-', 'prefetch-')) else 0
            with running(Loopback(url, size, block, variant.startswith('prefetch-'))) as proxy:
                result = playback(args.mpv, f'http://127.0.0.1:{proxy.server_port}{proxy.path}',
                                  observer, variant, size, args.timeout, args.vo,
                                  suffix in ('.ts', '.m2ts'), args.display)
                result.update(cacheHits=proxy.cache_hits, cachePeak=proxy.cache_peak)
        else:
            result = playback(args.mpv, url, observer, variant, size, args.timeout,
                              args.vo, suffix in ('.ts', '.m2ts'), args.display)
    records = origin.records.copy()
    segments = sorted((r['start'], r['start'] + r['bytesSent'])
                      for r in records if r['bytesSent'] and 'start' in r)
    duplicate = 0
    covered = 0
    for start, end in segments:
        duplicate += max(0, min(covered, end) - start)
        covered = max(covered, end)
    result.update(requests=records, media=media.name, mediaBytes=size, variant=variant,
                  upstreamConnections=origin.connections_seen,
                  duplicateUpstreamBytes=duplicate,
                  upstreamBytes=sum(r['bytesSent'] for r in records))
    return result


def print_summary(records):
    groups = {}
    for run in records:
        groups.setdefault((run['media'], run['variant']), []).append(run)
    for (media, variant), group in sorted(groups.items()):
        for key, values in {
            'restartMs': [r['restartMs'] for r in group if r['restartMs'] is not None],
            'firstVisibleMs': [r['firstVisibleMs'] for r in group if r['firstVisibleMs'] is not None],
            'firstSeekMs': [r['seekMs'][0] for r in group if r['seekMs']],
        }.items():
            if values:
                print(media, variant, key, len(values),
                      round(statistics.median(values)), round(sorted(values)[math.ceil(.95 * len(values)) - 1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpv', type=Path, required=True)
    parser.add_argument('--media', type=Path, action='append', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--variants', nargs='+', choices=BASELINE_VARIANTS + PROXY_VARIANTS + BLOCK_VARIANTS,
                        default=BASELINE_VARIANTS + ['proxy', 'block-1024'])
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--latency-ms', type=float, default=0)
    parser.add_argument('--mbps', type=float, default=0)
    parser.add_argument('--redirect', action='store_true')
    parser.add_argument('--origin-fault', choices=['no-range', 'invalid-range',
                                                  'unavailable', 'drop-once'])
    parser.add_argument('--timeout', type=float, default=35)
    parser.add_argument('--seconds', type=float, default=3)
    parser.add_argument('--vo', default='null')
    parser.add_argument('--display', action='store_true',
                        help='Show the MPV test window and sample a video marker on Windows')
    args = parser.parse_args()
    if args.display and (args.vo == 'null' or not hasattr(ctypes, 'windll')):
        parser.error('--display requires Windows and a visible video output')
    args.out.mkdir(parents=True, exist_ok=True)
    observer = args.out.resolve() / 'observer.lua'
    observer.write_text(make_observer(args.seconds), encoding='utf-8')
    samples = []
    for round_index in range(args.rounds):
        matrix = [(media, variant) for media in args.media for variant in args.variants]
        random.Random(413 + round_index).shuffle(matrix)
        for media, variant in matrix:
            result = run(args, media, variant, observer)
            samples.append(result)
            with (args.out / 'runs.jsonl').open('a', encoding='utf-8') as output:
                output.write(json.dumps(result) + '\n')
            startup = result['restartMs']
            seeks = result['seekMs']
            print(media.suffix, variant, round_index + 1,
                  round(startup) if startup else None,
                  round(statistics.median(seeks)) if seeks else None,
                  len(result['requests']), round(result['upstreamBytes'] / 1024**2),
                  result['code'], len(seeks), flush=True)
    print_summary(samples)


if __name__ == '__main__':
    main()
