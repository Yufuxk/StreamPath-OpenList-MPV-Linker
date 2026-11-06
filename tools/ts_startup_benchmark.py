"""Read-only mpv A/B diagnostics. No user configuration or OS cache eviction."""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import http.server
import json
import random
import re
import statistics
import subprocess
import threading
import time
from pathlib import Path


TS_STARTUP = ['--cache=no', '--demuxer-seekable-cache=no', '--cache-pause=yes',
              '--cache-pause-initial=yes', '--cache-pause-wait=5']
CONSERVATIVE = ['--cache=yes', '--cache-secs=30', '--demuxer-max-bytes=134217728',
                '--demuxer-seekable-cache=no', '--cache-pause=yes',
                '--cache-pause-initial=yes', '--cache-pause-wait=5']
VARIANTS = {'A': [], 'B': TS_STARTUP, 'C': CONSERVATIVE,
            'F': TS_STARTUP,
            'E': [v.replace('wait=5','wait=1') for v in TS_STARTUP],
            'P': CONSERVATIVE + ['--demuxer-lavf-probesize=1048576'],
            'Q': CONSERVATIVE + ['--demuxer-lavf-analyzeduration=1'],
            'D': CONSERVATIVE + ['--demuxer-lavf-probesize=1048576',
                                  '--demuxer-lavf-analyzeduration=1']}


class RangeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, files, latency_ms=0, mbps=0, redirect=False):
        super().__init__(('127.0.0.1', 0), RangeHandler)
        self.files = files
        self.latency_ms = latency_ms
        self.bytes_per_second = mbps * 125000
        self.redirect = redirect
        self.next_send = time.perf_counter()
        self.records = []
        self.active = 0
        self.lock = threading.Lock()


class RangeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        server = self.server
        is_redirect = self.path.startswith('/entry') and server.redirect
        path = server.files.get(self.path.replace('/entry', '/media', 1))
        if path is None:
            self.send_error(404)
            return
        began = time.perf_counter()
        record = {'method': self.command, 'bytesSent': 0, 'startedPerf': began}
        with server.lock:
            server.active += 1
            server.records.append(record)
        try:
            if is_redirect:
                if server.latency_ms:
                    time.sleep(server.latency_ms / 1000)
                record.update(status=302, redirect=True)
                self.send_response(302)
                self.send_header('Location', self.path.replace('/entry', '/media', 1))
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            size = path.stat().st_size
            start, end = 0, size - 1
            requested = self.headers.get('Range')
            if requested:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', requested)
                if not match:
                    self.send_error(416)
                    return
                start = int(match[1])
                end = min(int(match[2]), end) if match[2] else end
                if start > end:
                    self.send_error(416)
                    return
            record.update(start=start, end=end, range=bool(requested),
                          status=206 if requested else 200)
            if server.latency_ms:
                time.sleep(server.latency_ms / 1000)
            self.send_response(record['status'])
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Type', 'application/octet-stream')
            if requested:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            record['headersMs'] = (time.perf_counter() - began) * 1000
            if body:
                with path.open('rb') as source:
                    source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        chunk = source.read(min(262144, remaining))
                        if not chunk:
                            break
                        if server.bytes_per_second:
                            with server.lock:
                                now = time.perf_counter()
                                server.next_send = max(now, server.next_send) + len(chunk) / server.bytes_per_second
                                send_at = server.next_send
                            time.sleep(max(0, send_at - time.perf_counter()))
                        self.wfile.write(chunk)
                        record['bytesSent'] += len(chunk)
                        remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            record['clientClosed'] = True
        finally:
            record['elapsedMs'] = (time.perf_counter() - began) * 1000
            with server.lock:
                server.active -= 1


class ProcessMemory(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('faults', wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in ['peakWorkingSet', 'workingSet', 'peakPaged',
        'paged', 'peakNonPaged', 'nonPaged', 'commit', 'peakCommit']]


def memory_peak(process):
    if not hasattr(ctypes, 'windll'):
        return None
    read = ctypes.windll.psapi.GetProcessMemoryInfo
    read.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessMemory), wintypes.DWORD]
    read.restype = wintypes.BOOL
    value = ProcessMemory()
    value.cb = ctypes.sizeof(value)
    return value.peakWorkingSet if read(int(process._handle), ctypes.byref(value), value.cb) else None


def observer_source():
    source = (Path(__file__).resolve().parents[1] /
              'lib/domain/services/playback_startup_lua.dart').read_text('utf-8')
    return source.split("r'''", 1)[1].rsplit("''';", 1)[0]


def run_one(mpv, media, variant, mode, args, out, ordinal):
    observer = out / f'observer-{ordinal}.lua'
    source = observer_source()
    # B 仅模拟默认一秒轮询后的转换，不执行 AppState 或生产 IPC。
    if variant == 'B' and not args.resume:
        source += """
local switched = false
mp.register_event('playback-restart', function()
    if switched then return end
    switched = true
    mp.add_timeout(1, function()
        mp.set_property_number('demuxer-max-bytes', 134217728)
        mp.set_property_number('cache-secs', 30)
        mp.set_property('demuxer-seekable-cache', 'no')
        mp.set_property('cache', 'yes')
        mp.msg.info('SP_STARTUP {"event":"benchmarkRuntimeCacheApplied","model":true}')
    end)
end)
"""
    if variant in ('E', 'F') and not args.resume:
        source += """
local last_pos = nil
local switched = false
mp.add_periodic_timer(1, function()
    local pos = mp.get_property_number('time-pos')
    local good = pos and not mp.get_property_bool('pause', false)
        and not mp.get_property_bool('seeking', false)
        and not mp.get_property_bool('paused-for-cache', false)
    if not switched and good and last_pos and pos >= last_pos + 0.25 then
        switched = true
        mp.set_property_number('demuxer-max-bytes', 134217728)
        mp.set_property_number('cache-secs', 30)
        mp.set_property('demuxer-seekable-cache', 'no')
        mp.set_property('cache', 'yes')
    end
    last_pos = good and pos or nil
end)
"""
    source = source.replace("snapshot('playbackStable')", "snapshot('playbackStable')\n"
                            f"        mp.add_timeout({args.seconds}, function() mp.commandv('quit') end)")
    observer.write_text(source, encoding='utf-8')
    server = None
    if mode == 'http':
        server = RangeServer({'/media' + media.suffix.lower(): media}, args.latency_ms,
                             args.mbps, args.redirect)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        target = f'http://127.0.0.1:{server.server_port}/{"entry" if args.redirect else "media"}{media.suffix.lower()}'
    else:
        target = str(media)
    options = CONSERVATIVE if variant in ('B', 'E', 'F') and args.resume else VARIANTS[variant]
    command = [str(mpv), '--no-config', '--load-scripts=no', '--vo=null', '--ao=null',
               '--hwdec=no', '--no-resume-playback', '--rebase-start-time=yes',
               '--msg-level=all=info', '--script=' + str(observer), *options]
    if args.initial_buffer is not None:
        command.append('--cache-pause-initial=' + args.initial_buffer)
    if args.resume:
        command.append(f'--start={args.resume}')
    command.append(target)
    events = []
    peak_memory = 0
    began = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               encoding='utf-8', errors='replace',
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    created_ms = (time.perf_counter() - began) * 1000
    timed_out = threading.Event()

    def timeout():
        timed_out.set()
        process.kill()

    watchdog = threading.Timer(args.timeout, timeout)
    watchdog.start()
    try:
        for line in process.stdout:
            if 'SP_STARTUP ' in line:
                event = json.loads(line.split('SP_STARTUP ', 1)[1])
                event['receivedMs'] = (time.perf_counter() - began) * 1000
                events.append(event)
                peak_memory = max(peak_memory, memory_peak(process) or 0)
        process.wait()
    finally:
        watchdog.cancel()
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        if server:
            server.shutdown()
            server.server_close()
            deadline = time.perf_counter() + 3
            while server.active and time.perf_counter() < deadline:
                time.sleep(.01)
    loaded = next((e for e in events if e['event'] == 'mpvFileLoaded'), None)
    restarts = [e for e in events if e['event'] == 'mpvPlaybackRestart']
    stable = next((e for e in events if e['event'] == 'playbackStable'), None)
    requests = []
    for raw in server.records if server else []:
        record = dict(raw)
        record['startMs'] = (record.pop('startedPerf') - began) * 1000
        requests.append(record)
    return {'variant': variant, 'mode': mode, 'sourceName': media.name,
            'sourceBytes': media.stat().st_size, 'sourceMtimeNs': media.stat().st_mtime_ns,
            'osCache': 'uncontrolled-no-eviction',
            'output': 'null-audio-video', 'resume': args.resume,
            'args': command[1:-1], 'processCreatedMs': created_ms,
            'fileLoadedMs': loaded['receivedMs'] if loaded else None,
            'playbackRestartMs': restarts[0]['receivedMs'] if restarts else None,
            'stableMs': stable['receivedMs'] if stable else None,
            'firstVideoFrameMs': None, 'windowShownMs': None,
            'eventTiming': 'stdout-receipt proxy; mpvElapsedSec is a separate clock',
            'peakWorkingSetBytes': peak_memory or None,
            'bufferPauseEvents': sum(e['event']=='mpvBufferingChanged' and e.get('pausedForCache') is True for e in events),
            'playingStallEvents': sum(e['event']=='mpvBufferingChanged' and e.get('pausedForCache') is True and (e.get('position') or 0) > args.resume + 1 for e in events),
            'exitCode': process.returncode, 'timedOut': timed_out.is_set(),
            'requests': requests, 'requestCount': len(requests),
            'bytesSent': sum(r['bytesSent'] for r in requests),
            'pendingRequests': server.active if server else 0, 'events': events}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpv', type=Path, required=True)
    parser.add_argument('--media', type=Path, action='append', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--variants', nargs='+', choices=VARIANTS, default=['A', 'B', 'C', 'D'])
    parser.add_argument('--modes', nargs='+', choices=['local', 'http'], default=['local', 'http'])
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--latency-ms', type=float, default=0)
    parser.add_argument('--mbps', type=float, default=0, help='Aggregate response-body bandwidth; 0 means unlimited')
    parser.add_argument('--redirect', action='store_true', help='Add one same-origin HTTP 302 before the media')
    parser.add_argument('--resume', type=float, default=0)
    parser.add_argument('--initial-buffer', choices=['yes', 'no'], help='Single-variable override for initial buffering')
    args = parser.parse_args()
    if (args.rounds < 1 or args.seconds <= 0 or args.timeout <= args.seconds
            or args.latency_ms < 0 or args.mbps < 0 or args.resume < 0):
        parser.error('Use positive rounds/seconds, timeout > seconds, and nonnegative latency/mbps/resume')
    if not all(media.is_file() for media in args.media):
        parser.error('Every --media must be an existing regular file')
    args.out.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(args.mpv), '--version'], text=True, encoding='utf-8')
    supported = subprocess.check_output([str(args.mpv), '--no-config', '--list-options'],
                                        text=True, encoding='utf-8', errors='replace')
    for option in {value.split('=')[0][2:] for v in args.variants for value in VARIANTS[v]}:
        if not re.search(r'^\s*--' + re.escape(option) + r'\s', supported, re.M):
            raise SystemExit('Unsupported mpv option: ' + option)
    manifest = {'version': version, 'mpvSha256': hashlib.sha256(args.mpv.read_bytes()).hexdigest(),
                'rounds': args.rounds, 'latencyMs': args.latency_ms,
                'mbps': args.mbps, 'redirect': args.redirect,
                'initialBufferOverride': args.initial_buffer,
                'observerSha256': hashlib.sha256(observer_source().encode()).hexdigest(),
                'cacheEviction': False, 'userConfigLoaded': False, 'runs': []}
    jobs = [(media.resolve(), mode, variant) for media in args.media
            for mode in args.modes for variant in args.variants]
    for repeat in range(args.rounds):
        random.Random(61106 + repeat).shuffle(jobs)
        for media, mode, variant in jobs:
            result = run_one(args.mpv, media, variant, mode, args, args.out,
                             len(manifest['runs']))
            result['round'] = repeat + 1
            manifest['runs'].append(result)
            (args.out / 'results.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), 'utf-8')
            print(json.dumps({k: result[k] for k in ['round', 'sourceName', 'variant', 'mode',
                  'fileLoadedMs', 'playbackRestartMs', 'stableMs', 'requestCount', 'bytesSent', 'exitCode']},
                  ensure_ascii=True), flush=True)
    summaries = []
    for media, mode, variant in jobs:
        rows = [r for r in manifest['runs'] if r['sourceName'] == media.name
                and r['mode'] == mode and r['variant'] == variant]
        summary = {'source': media.name, 'mode': mode, 'variant': variant, 'n': len(rows)}
        for key in ['fileLoadedMs', 'playbackRestartMs', 'stableMs', 'requestCount', 'bytesSent']:
            values = sorted(r[key] for r in rows if r[key] is not None)
            if values:
                summary[key] = {'median': statistics.median(values), 'min': values[0],
                                'max': values[-1], 'p95': values[min(len(values)-1, int(len(values)*.95))]}
        summaries.append(summary)
    (args.out / 'summary.json').write_text(json.dumps(summaries, ensure_ascii=False, indent=2), 'utf-8')
    if any(r['exitCode'] != 0 or not r['fileLoadedMs'] or not r['playbackRestartMs']
           for r in manifest['runs']):
        raise SystemExit('Incomplete playback runs; inspect results.json')


if __name__ == '__main__':
    main()
