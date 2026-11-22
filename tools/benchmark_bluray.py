"""Read-only Blu-ray benchmark with a local, bounded HTTP source."""
import argparse, ctypes, hashlib, http.server, json, os, pathlib, struct, subprocess, threading, time, urllib.parse, urllib.request, uuid, msvcrt
from ctypes import wintypes

def process_resources(pid):

    class Memory(ctypes.Structure):
        _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [(n, ctypes.c_size_t) for n in ['PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage', 'PrivateUsage']]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(4112, False, pid)
    if not handle:
        return None
    try:
        memory = Memory()
        memory.cb = ctypes.sizeof(memory)
        psapi = ctypes.WinDLL('psapi')
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Memory), wintypes.DWORD]
        if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb):
            return None
        result = dict(pid=pid, privateBytes=memory.PrivateUsage, workingSetBytes=memory.WorkingSetSize, peakWorkingSetBytes=memory.PeakWorkingSetSize)
        count = wintypes.DWORD()
        kernel.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        if kernel.GetProcessHandleCount(handle, ctypes.byref(count)):
            result['handles'] = count.value
        stamps = [wintypes.FILETIME() for _ in range(4)]
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        if kernel.GetProcessTimes(handle, *[ctypes.byref(stamp) for stamp in stamps]):
            result['cpuSeconds'] = sum((stamp.dwHighDateTime << 32) + stamp.dwLowDateTime for stamp in stamps[2:]) / 10000000
        return result
    finally:
        kernel.CloseHandle(handle)

class Source:

    def __init__(self, root, delay, bandwidth, outage, max_concurrent_requests=0,
                 per_request_bandwidth=0, max_large_ranges=0):
        self.root = pathlib.Path(root).resolve()
        self.count = 0
        self.bytes = 0
        self.delay = delay / 1000
        self.bandwidth = bandwidth * 1048576
        self.per_request_bandwidth = per_request_bandwidth * 1048576
        self.lock = threading.Lock()
        self.next = 0
        self.started = time.monotonic()
        self.outage = outage
        self.max_concurrent_requests = max_concurrent_requests
        self.max_large_ranges = max_large_ranges
        self.active_large = 0
        self.active = self.peak = self.rejected = 0
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *a):
                pass

            def handle(self):
                try:
                    super().handle()
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                    pass

            def do_HEAD(self):
                self.serve(True)

            def do_GET(self):
                self.serve(False)

            def serve(self, head):
                large = False
                if owner.max_large_ranges and not head:
                    value = self.headers.get('Range', '')
                    start, separator, end = value.removeprefix('bytes=').partition('-')
                    large = (separator and start.isdecimal() and end.isdecimal()
                             and int(end) - int(start) + 1 >= 8 * 1048576)
                with owner.lock:
                    owner.active += 1
                    owner.active_large += bool(large)
                    owner.peak = max(owner.peak, owner.active)
                    reject = ((owner.max_concurrent_requests and owner.active > owner.max_concurrent_requests)
                              or (large and owner.active_large > owner.max_large_ranges))
                    if reject:
                        owner.rejected += 1
                try:
                    if reject:
                        self.send_response(429)
                        self.send_header('Content-Length', '0')
                        self.end_headers()
                        return
                    self.serve_range(head)
                finally:
                    with owner.lock:
                        owner.active -= 1
                        owner.active_large -= bool(large)

            def serve_range(self, head):
                path = (owner.root / urllib.parse.unquote(self.path).lstrip('/')).resolve() if owner.root.is_dir() else owner.root
                if owner.root.is_dir() and (not path.is_relative_to(owner.root)) or not path.is_file():
                    self.send_error(404)
                    return
                st = path.stat()
                size = st.st_size
                etag = '"%x-%x"' % (size, st.st_mtime_ns)
                start, end = (0, size - 1)
                value = self.headers.get('Range')
                valid = self.headers.get('If-Range') in (None, etag)
                if value and valid:
                    a, b = value.removeprefix('bytes=').split('-')
                    start = int(a)
                    end = int(b) if b else size - 1
                    if not 0 <= start <= end < size:
                        self.send_error(416)
                        return
                time.sleep(owner.delay)
                with owner.lock:
                    owner.count += 1
                try:
                    self.send_response(206 if value and valid else 200)
                    self.send_header('Content-Length', str(end - start + 1))
                    self.send_header('ETag', etag)
                    if value and valid:
                        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                    self.end_headers()
                    if head:
                        return
                    next_send = 0
                    with path.open('rb') as f:
                        f.seek(start)
                        remaining = end - start + 1
                        while remaining:
                            if owner.outage:
                                elapsed = time.monotonic() - owner.started
                                phase = elapsed % 40
                                if elapsed >= 40 and phase < owner.outage:
                                    time.sleep(owner.outage - phase)
                            data = f.read(min(65536, remaining))
                            if not data:
                                raise IOError('Short source read')
                            if owner.per_request_bandwidth:
                                next_send = max(time.monotonic(), next_send) + len(data) / owner.per_request_bandwidth
                                time.sleep(max(0, next_send - time.monotonic()))
                            if owner.bandwidth:
                                with owner.lock:
                                    owner.next = max(time.monotonic(), owner.next) + len(data) / owner.bandwidth
                                    send_at = owner.next
                                time.sleep(max(0, send_at - time.monotonic()))
                            self.wfile.write(data)
                            with owner.lock:
                                owner.bytes += len(data)
                            remaining -= len(data)
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                    pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'

    def manifest(self):
        entries = sorted([p for n in ['BDMV', 'CERTIFICATE'] if (self.root / n).exists() for p in [self.root / n, *list((self.root / n).rglob('*'))]], key=lambda p: (len(p.relative_to(self.root).parts), p.as_posix()))
        for path in entries:
            rel = path.relative_to(self.root).as_posix()
            st = path.stat()
            folder = path.is_dir()
            yield dict(type='disc_file', path=rel, url=self.base + '/' + urllib.parse.quote(rel), size=0 if folder else st.st_size, directory=folder, **{} if folder else {'etag': '"%x-%x"' % (st.st_size, st.st_mtime_ns)})

    def close(self):
        self.server.shutdown()
        self.server.server_close()

class Control:

    def __init__(self, name, process):
        self.file = None
        for _ in range(200):
            try:
                self.file = open(chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + name, 'r+b', buffering=0)
                return
            except FileNotFoundError:
                if process.poll() is not None:
                    raise RuntimeError('Process exited before pipe connected')
                time.sleep(0.05)
        raise TimeoutError('Control pipe missing')

    def read(self, n):
        data = b''
        while len(data) < n:
            value = self.file.read(n - len(data))
            if not value:
                raise EOFError('Control pipe closed')
            data += value
        return data

    def receive(self):
        return json.loads(self.read(struct.unpack('<I', self.read(4))[0]))

    def send(self, message):
        data = json.dumps(message, separators=(',', ':')).encode()
        frame = struct.pack('<I', len(data)) + data
        offset = 0
        while offset < len(frame):
            offset += self.file.write(frame[offset:])

    def close(self):
        self.file.close()

class MpvControl(Control):

    def __init__(self, name, process):
        super().__init__(name, process)
        self.serial = 0
        self.buffer = b''
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.PeekNamedPipe.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        self.kernel.PeekNamedPipe.restype = wintypes.BOOL

    def command(self, *args):
        self.serial += 1
        self.file.write(json.dumps(dict(command=args, request_id=self.serial)).encode() + b'\n')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                value = json.loads(line)
                if value.get('request_id') == self.serial:
                    return value
            n = wintypes.DWORD()
            if not self.kernel.PeekNamedPipe(msvcrt.get_osfhandle(self.file.fileno()), None, 0, None, ctypes.byref(n), None):
                return dict(error='closed')
            if n.value:
                self.buffer += self.file.read(n.value)
            else:
                time.sleep(0.01)
        return dict(error='timeout')

def run(args):
    root = pathlib.Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    source = Source(args.source, args.delay_ms, args.mibps, args.outage,
                    args.max_concurrent_requests, args.per_request_mibps,
                    args.max_large_ranges)
    player = helper = control = ipc = None
    samples = []
    began = time.monotonic()
    try:
        session = root / 'session'
        session.mkdir()
        name = 'streampath_bluray_' + uuid.uuid4().hex
        with (root / 'helper.log').open('wb') as log:
            helper = subprocess.Popen([str(pathlib.Path(args.helper).resolve()), '--pipe=' + name, '--parent-pid=' + str(os.getpid())], stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
        control = Control(name, helper)
        hello = control.receive()
        cache = pathlib.Path(args.cache).resolve() if args.cache else root / 'iso_structure' / ('a' * 64 + '.cache')
        request = dict(type='open_disc' if args.mode == 'menu' else 'open', version=1, url=source.base + '/disc.iso', origin=source.base, username='', password='', sessionPath=str(session), structureCachePath=str(cache))
        if args.mode == 'menu':
            request.update(mode='disc-menu' if hello.get('discMenuVersion') == 1 else 'hdmv', transport='winfsp')
        if args.local:
            request['localPath'] = str(source.root.resolve())
        if args.single:
            if hello.get('mainFeatureVersion') != 1:
                raise RuntimeError('Helper does not support focused discovery')
            request['mainFeature'] = True
        if args.confirmation:
            snapshot = json.loads(pathlib.Path(args.confirmation).read_text(encoding='utf8'))
            confirmed = next(item for item in snapshot['candidates']
                             if item['playlist'] == int(args.playlist))
            revision = snapshot['revision']
            if not revision:
                raise RuntimeError('Candidate has no verified source revision')
            if args.stale_confirmation:
                revision = '0' * 64 + revision[64:]
            request.update(confirmedRevision=revision, confirmedPlaylist=confirmed['playlist'],
                           confirmedTitleIndex=confirmed['titleIndex'])
        if source.root.is_dir():
            request['sourceKind'] = 'bdmv'
        control.send(request)
        if source.root.is_dir():
            for item in source.manifest():
                control.send(item)
            control.send(dict(type='files_end'))
        while True:
            ready = control.receive()
            if ready['type'] == 'titleCandidates':
                (root / 'candidates.json').write_text(json.dumps(ready, indent=2), encoding='utf8')
                reply = dict(type='selectCandidate')
                if args.single == 'select':
                    if int(args.playlist) not in [item['playlist'] for item in ready['candidates']]:
                        raise RuntimeError('Requested candidate is missing')
                    reply['playlist'] = int(args.playlist)
                control.send(reply)
                continue
            if ready['type'] != 'metrics':
                break
        if args.confirmation and (root / 'candidates.json').exists() != args.stale_confirmation:
            raise RuntimeError('Unexpected reuse of confirmed programme')
        prepare_ms = (time.monotonic() - began) * 1000
        public_ready = {key: value for key, value in ready.items() if key != 'token'}
        (root / 'ready.json').write_text(json.dumps(public_ready, indent=2), encoding='utf8')
        if ready['type'] != 'ready':
            raise RuntimeError(ready)
        if args.single == 'select' and not ready.get('mainFeatureSelected'):
            raise RuntimeError('Helper did not materialize the selected title')
        if args.mode == 'title':
            title = (next(title for title in ready['titles']
                          if (title.get('programmeId') or title.get('mplsId')) == args.playlist)
                     if args.playlist else max(ready['titles'], key=lambda t: t['durationMs']))
            programme = title.get('programmeId') or title.get('mplsId')
            route = (f'dvd/title/{int(programme[10:]):05}.vob'
                     if programme.startswith('dvd-title-') else f'title/{programme}.m2ts')
            playback_url = f"http://127.0.0.1:{ready['port']}/{ready['token']}/{route}"
        print(json.dumps(dict(mode=args.mode, prepareMs=round(prepare_ms, 2), metadataRequests=source.count, metadataBytes=source.bytes)), flush=True)
        if args.verify_bytes:
            checks = []
            if args.mode == 'menu':
                if source.root.is_dir():
                    files = [source.root / 'BDMV/index.bdmv']
                    files += [next((source.root / 'BDMV' / name).glob('*.' + extension)) for name, extension in [('BDJO', 'bdjo'), ('JAR', 'jar')]]
                    files += [max((source.root / 'BDMV/STREAM').glob('*.m2ts'), key=lambda p: p.stat().st_size)]
                    pairs = [(file, pathlib.Path(ready['discPath']) / file.relative_to(source.root)) for file in files]
                else:
                    pairs = [(source.root, pathlib.Path(ready['discPath']))]
                for original, mounted in pairs:
                    size = original.stat().st_size
                    for offset in sorted({0, min(size // 2, 6000000000), max(0, size - 65536)}):
                        with original.open('rb') as reference, mounted.open('rb') as actual:
                            reference.seek(offset)
                            actual.seek(offset)
                            expected = reference.read(min(65536, size - offset))
                            data = actual.read(len(expected))
                        if data != expected:
                            raise RuntimeError('Mounted bytes differ from the read-only source')
                        checks.append(dict(file=original.name, offset=offset, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            else:
                length = title['size']
                tail = max(0, length - 65536)
                for offset in sorted({0, min(3 * 1024 ** 3, tail), tail}):
                    end = min(length - 1, offset + 65535)
                    request = urllib.request.Request(playback_url, headers={'Range': f'bytes={offset}-{end}'})
                    with urllib.request.urlopen(request, timeout=60) as response:
                        data = response.read()
                        if response.status != 206 or len(data) != end - offset + 1:
                            raise RuntimeError('Title Range response is incomplete')
                    checks.append(dict(offset=offset, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            (root / 'byte-checks.json').write_text(json.dumps(checks, indent=2), encoding='utf8')
        if args.prepare_only:
            control.send(dict(type='shutdown'))
            control.close()
            control = None
            helper.wait(timeout=15)
            return
        if not (args.mode == 'menu' and args.local):
            control.send(dict(type='configure_cache', blockCount=args.cache_blocks, prefetchBlocks=args.prefetch_blocks, **{'cacheSecs': 60} if args.mode == 'menu' else {}))
            assert control.receive().get('configured') is True
        env = os.environ.copy()
        if args.runtime:
            runtime = pathlib.Path(args.runtime).resolve()
            cache_root = root / 'java-cache'
            persistent = root / 'java-persistent'
            cache_root.mkdir()
            persistent.mkdir()
            env.update(JAVA_HOME=str(runtime / 'java'), LIBBLURAY_CP=str(runtime / 'libbluray-j2se-1.5.0.jar'), LIBBLURAY_CACHE_ROOT=str(cache_root), LIBBLURAY_PERSISTENT_ROOT=str(persistent))
        pipe = 'streampath_bluray_mpv_' + uuid.uuid4().hex
        events = root / 'mpv-events.jsonl'
        probe = root / 'events.lua'
        probe.write_text("local mp=require 'mp'\nlocal u=require 'mp.utils'\nlocal started=mp.get_time()\nlocal function record(event, observed) local paused=mp.get_property_native('paused-for-cache'); if event=='cache-pause' then paused=observed end; local f=assert(io.open(" + json.dumps(str(events)) + ", 'ab')); f:write(u.format_json({event=event,ms=(mp.get_time()-started)*1000,menu=mp.get_property_native('disc-menu-active'),position=mp.get_property_number('time-pos'),duration=mp.get_property_number('duration'),paused=paused}), '\\n'); f:close() end\nmp.register_script_message('benchmark-clock',function() record('clock') end)\nmp.observe_property('paused-for-cache','bool',function(_, value) record('cache-pause', value) end)\nmp.register_event('file-loaded', function() record('file-loaded') end)\nmp.register_event('playback-restart', function() record('playback-restart') end)\nmp.observe_property('disc-menu-active','bool',function() record('menu') end)\n", encoding='utf8')
        common = [args.mpv, '--no-config', '--terminal=yes', '--input-terminal=no', '--vo=gpu-next' if args.visible else '--vo=null', '--ao=null', '--hwdec=auto-safe' if args.visible else '--hwdec=auto-copy', '--idle=no', '--keep-open=no', '--script='+str(probe), '--cache=yes', '--demuxer-max-bytes=' + str(args.mpv_cache_mib * 1048576), '--demuxer-max-back-bytes=0', '--input-ipc-server=' + chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + pipe]
        if args.mode == 'menu':
            common += ['--bluray-device=' + ready['discPath'], 'bd://menu']
        else:
            common += ['--start=600', playback_url]
        with (root / 'mpv.log').open('wb') as log:
            spawn_started = time.monotonic()
            player = subprocess.Popen(common, env=env, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
        control.send(dict(type='attachPlayer', pid=player.pid))
        assert control.receive().get('attached') is True
        control.close()
        control = None
        ipc = MpvControl(pipe, player)
        clock_sent = time.monotonic()
        ipc.command('script-message', 'benchmark-clock')
        clock_event = None
        while time.monotonic() - clock_sent < 5:
            if events.exists():
                for line in events.read_text(encoding='utf8').splitlines():
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if entry['event'] == 'clock':
                        clock_event = entry
                        break
            if clock_event:
                break
            time.sleep(0.01)
        if not clock_event:
            raise RuntimeError('MPV clock alignment did not complete')
        clock_ack = time.monotonic()
        alignment = dict(beforePlayerMs=(spawn_started - began) * 1000,
                         offsetMs=((clock_sent + clock_ack) / 2 - spawn_started) * 1000 - clock_event['ms'],
                         uncertaintyMs=(clock_ack - clock_sent) * 500)
        (root / 'clock.json').write_text(json.dumps(alignment, indent=2), encoding='utf8')
        play_started = spawn_started
        actions = set()
        menu_visible_since = None
        seek_points = [0.5, 0.1, 0.8, 0.2, 0.96, 0.4]
        while time.monotonic() - play_started < args.seconds and player.poll() is None:
            elapsed = time.monotonic() - play_started
            if args.mode == 'menu':
                for at, command in [(5, ('discnav', 'menu')), (45, ('discnav', 'select')), (80, ('discnav', 'select'))]:
                    if elapsed >= at and at not in actions:
                        actions.add(at)
                        samples.append(dict(ms=round(elapsed * 1000), command=command, result=ipc.command(*command)))
            if args.seconds >= 180 and elapsed >= args.seconds / 2 and ('seek' not in actions):
                actions.add('seek')
                samples.append(dict(ms=round(elapsed * 1000), command='seek', result=ipc.command('seek', 1200, 'absolute+exact')))
            if args.seek_stress and seek_points and elapsed >= args.seek_start + 4 * (6 - len(seek_points)):
                duration = title['durationMs'] / 1000
                target = round(duration * seek_points.pop(0), 3)
                samples.append(dict(ms=round(elapsed * 1000), command='seek', target=target,
                                    result=ipc.command('seek', target, 'absolute+exact')))
            if args.visible and elapsed > args.seconds - 3 and ('screenshot' not in actions):
                actions.add('screenshot')
                ipc.command('screenshot-to-file', str(root / 'menu.png'), 'window')
            if args.seconds >= 180:
                for at, command in [(args.seconds / 2 + 30, ('discnav', 'popup')), (args.seconds / 2 + 35, ('discnav', 'popup')), (args.seconds - 20, ('discnav', 'menu'))] if args.mode == 'menu' else []:
                    if elapsed >= at and at not in actions:
                        actions.add(at)
                        samples.append(dict(ms=round(elapsed * 1000), command=command, result=ipc.command(*command)))
            row = dict(ms=round(elapsed * 1000), bridgeProcess=process_resources(helper.pid), mpvProcess=process_resources(player.pid))
            for key in ['disc-menu-active', 'current-edition', 'duration', 'time-pos', 'paused-for-cache', 'demuxer-cache-duration', 'chapter', 'sid', 'aid', 'vo-drop-frame-count', 'decoder-frame-drop-count', 'hwdec-current']:
                row[key] = ipc.command('get_property', key).get('data')
            if row.get('disc-menu-active') is True:
                menu_visible_since = menu_visible_since if menu_visible_since is not None else elapsed
                if args.visible and elapsed - menu_visible_since >= 2 and 'menu-screenshot' not in actions:
                    actions.add('menu-screenshot')
                    ipc.command('screenshot-to-file', str(root / 'native-menu.png'), 'window')
            else:
                menu_visible_since = None
            samples.append(row)
            time.sleep(0.5)
        play_elapsed = time.monotonic() - play_started
        if player.poll() is not None and play_elapsed < args.seconds - 2:
            raise RuntimeError('MPV exited before the requested observation window')
        ipc.command('quit')
        ipc.close()
        ipc = None
        player.wait(timeout=15)
        helper.wait(timeout=20)
    finally:
        if control:
            control.close()
        if ipc:
            ipc.close()
        for proc in [player, helper]:
            if proc and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)
        source.close()
        (root / 'samples.json').write_text(json.dumps(samples, indent=2), encoding='utf8')
        metrics = root / 'session' / 'iso-bridge-metrics.json'
        result = dict(mode=args.mode, prepareMs=round(locals().get('prepare_ms', 0), 2), requestedSeconds=args.seconds, measuredPlaybackSeconds=round(locals().get('play_elapsed', 0), 2), delayMs=args.delay_ms, MiBps=args.mibps, serverRequests=source.count, serverBytes=source.bytes, menuObserved=any((s.get('disc-menu-active') is True for s in samples)), mainFeatureObserved=any(((s.get('duration') or 0) > 6000 and (s.get('time-pos') or 0) > 3 and s.get('disc-menu-active') is not True for s in samples)), cachePausedSamples=sum((s.get('paused-for-cache') is True for s in samples)), headless=not args.visible)
        result.update(serverRejected429=source.rejected, serverConcurrentPeak=source.peak)
        result.update(perRequestMiBps=args.per_request_mibps, maxLargeRanges=args.max_large_ranges)
        result.update(single=args.single, local=args.local, playlist=args.playlist,
                      helperExit=helper.poll() if helper is not None else None,
                      mpvExit=player.poll() if player is not None else None,
                      seekCommands=sum(row.get('command') == 'seek' for row in samples))
        if 'alignment' in locals():
            entries = [json.loads(line) for line in events.read_text(encoding='utf8').splitlines()]
            result['clockUncertaintyMs'] = round(alignment['uncertaintyMs'], 2)
            result['cachePauseEvents'] = sum(entry['event'] == 'cache-pause' and entry.get('paused') is True for entry in entries)
            for event, name in [('file-loaded', 'fileLoadedMs'), ('playback-restart', 'playbackRestartMs')]:
                first = next((entry['ms'] for entry in entries if entry['event'] == event), None)
                if first is not None:
                    result[name] = round(alignment['beforePlayerMs'] + alignment['offsetMs'] + first, 2)
        (root / 'summary.json').write_text(json.dumps(result, indent=2), encoding='utf8')
        print(json.dumps(result), flush=True)
if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for field in ['source', 'helper', 'output']:
        parser.add_argument('--' + field, required=True)
    parser.add_argument('--mode', choices=['title', 'menu'], required=True)
    parser.add_argument('--mpv')
    parser.add_argument('--runtime')
    parser.add_argument('--cache')
    parser.add_argument('--delay-ms', type=float, default=20)
    parser.add_argument('--mibps', type=float, default=20)
    parser.add_argument('--per-request-mibps', type=float, default=0)
    parser.add_argument('--outage', type=float, default=0)
    parser.add_argument('--max-concurrent-requests', type=int, default=0)
    parser.add_argument('--max-large-ranges', type=int, default=0, help='Limit concurrent Range requests of at least 8 MiB')
    parser.add_argument('--seconds', type=int, default=65)
    parser.add_argument('--cache-blocks', type=int, default=16)
    parser.add_argument('--prefetch-blocks', type=int, default=12)
    parser.add_argument('--mpv-cache-mib', type=int, default=16)
    parser.add_argument('--visible', action='store_true')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--verify-bytes', action='store_true')
    parser.add_argument('--playlist', help='Use this exact programme ID in both benchmark variants')
    parser.add_argument('--single', choices=['select', 'fallback'])
    parser.add_argument('--confirmation', help='Reuse the verified revision from a candidates.json snapshot')
    parser.add_argument('--stale-confirmation', action='store_true')
    parser.add_argument('--local', action='store_true', help='Use the direct local Bridge source')
    parser.add_argument('--seek-stress', action='store_true')
    parser.add_argument('--seek-start', type=float, default=8, help='Seconds before the first stress seek')
    args = parser.parse_args()
    if not args.prepare_only and (not args.mpv):
        parser.error('--mpv is required for playback')
    if min(args.delay_ms, args.mibps, args.per_request_mibps, args.outage, args.max_concurrent_requests,
           args.max_large_ranges, args.seek_start) < 0 or args.outage >= 40 or args.seconds <= 0:
        parser.error('Invalid shaping or duration')
    if args.mode == 'menu' and (args.single or args.playlist or args.seek_stress):
        parser.error('Single, playlist and seek-stress require title mode')
    if args.single == 'select' and (not args.playlist or not args.playlist.isascii() or
                                   not args.playlist.isdecimal() or len(args.playlist) != 5):
        parser.error('Single selection requires a five-digit MPLS ID')
    if (args.confirmation and args.single != 'select') or (args.stale_confirmation and not args.confirmation):
        parser.error('Confirmation checks require --single select and a candidate snapshot')
    run(args)
