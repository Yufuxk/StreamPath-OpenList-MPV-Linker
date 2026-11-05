"""Read-only DVD VM/ILVU fixtures with real MPEG payload and exact Range checks."""
import argparse
import concurrent.futures
import socket
import time
import hashlib
import json
from pathlib import Path
import random
import subprocess
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from validate_dvd_iso import Bridge, IsoServer
from validate_dvd_variants import number, put, variant


def ilvu_fixture(original, mode):
    data = bytearray(original)
    vmg = data.index(b'DVDVIDEO-VMG')
    vts = data.index(b'DVDVIDEO-VTS')
    titles = vmg + number(data, vmg + 196) * 2048
    data[titles + 9] = 2
    pgcit = vts + number(data, vts + 204) * 2048
    pgc = pgcit + number(data, pgcit + 12)
    program = pgc + number(data, pgc + 230, 2)
    playback = pgc + number(data, pgc + 232, 2)
    positions = pgc + number(data, pgc + 234, 2)
    admap = vts + number(data, vts + 228) * 2048
    base = vts + number(data, vts + 196) * 2048
    navs = [number(data, admap + i) for i in range(4, number(data, admap) + 1, 4)]
    first = number(data, playback + 8)
    index = navs.index(first)
    units = [original[base + navs[i]*2048:base + navs[i+1]*2048]
             for i in range(index, index + (5 if mode == 'ilvu-multi-vobu' else 4))]
    # A0 B0 A1 B1 A2 B2 then a common cell: both angles have the same timeline.
    multi = mode == 'ilvu-multi-vobu'
    order = [0, 1, 0, 1, 2, 3, 2, 3, 4] if multi else [0, 0, 1, 1, 2, 2, 3]
    common = len(order)-1
    a_last, b_first, b_last = (5, 2, 7) if multi else (4, 1, 5)
    starts, cursor = [], first
    for source in order:
        starts.append(cursor)
        cursor += len(units[source]) // 2048
    for n, source in enumerate(order):
        unit = bytearray(units[source])
        dsi = 1031
        put(unit, 45, starts[n])
        put(unit, dsi + 4, starts[n])
        # One VOBU per angle per ILVU; selected angle must skip the other payload.
        put(unit, dsi + 32, ((0x6000 if n % 2 == 0 else 0x5000) if multi else 0x5000) if n < common else 0, 2)
        put(unit, dsi + 34, len(unit)//2048 - 1)
        unit[45+60:45+96] = bytes(36)  # Non-seamless angle destinations.
        unit[dsi+180:dsi+234] = bytes(54)
        if n == common:
            unit[45+24:45+28] = bytes([0, 0, 0, 0xc0])
            unit[dsi+28:dsi+32] = bytes([0, 0, 0, 0xc0])
        end = n in (a_last, b_last, common)
        if n < common and (not multi or n % 2 == 1):
            next_a = 4 if multi else (n//2+1)*2
            next_b = 6 if multi else next_a+1
            put(unit, dsi+180, 0x3fffffff if end else starts[next_a]-starts[n])
            put(unit, dsi+186, 0x3fffffff if end else starts[next_b]-starts[n])
        put(unit, dsi + 314, 0x3fffffff if end else starts[n+1] - starts[n])
        unit[dsi+27] = 3 if n == common else (1 if (n//2 if multi else n) % 2 == 0 else 2)
        data[base+starts[n]*2048:base+starts[n]*2048+len(unit)] = unit
    data[pgc+2:pgc+4] = bytes([2, 3])
    data[program:program+2] = bytes([1, 3])
    # PTTs refer to the two actual programs; unused old entries are duplicates.
    ptt = vts + number(data, vts+200)*2048
    table = ptt + number(data, ptt+8)
    for i in range(number(data, titles+10, 2)):
        put(data, table+i*4+2, 1 if i == 0 else 2, 2)
    # First three VOBUs occupy 1.5 seconds in the supplied NTSC sample.
    angle_time = bytes([0, 0, 2, 0xc0]) if multi else bytes([0, 0, 1, 0xc0 | 0x15])
    common_time = bytes([0, 0, 0, 0xc0 | 0x15])
    for n in range(3):
        cell = bytearray(24)
        cell[0] = [0x54, 0xd4, 0][n]
        cell[4:8] = angle_time if n < 2 else common_time
        begin = starts[0 if n == 0 else b_first] if n < 2 else starts[common]
        last = starts[b_last] + len(units[order[b_last]])//2048 - 1 if n < 2 else cursor - 1
        put(cell, 8, begin)
        put(cell, 12, starts[(1 if n == 0 else 3) if multi else n] + len(units[1 if multi else 0])//2048 - 1 if n < 2 else begin)
        put(cell, 16, starts[a_last if n == 0 else b_last] if n < 2 else begin)
        put(cell, 20, last)
        data[playback+n*24:playback+(n+1)*24] = cell
        data[positions+n*4:positions+(n+1)*4] = data[positions:positions+4]
        data[positions+n*4+3] = n+1
    data[pgc+4:pgc+8] = bytes([0, 0, 2, 0xc0])
    put(data, admap, 4 + len(starts)*4 - 1)
    for n, start in enumerate(starts):
        put(data, admap+4+n*4, start)
    if mode == 'ilvu-angle-still':
        data[pgc+2:pgc+4] = bytes([1, 2])
        data[pgc+163] = 1
        for i in range(number(data, titles+10, 2)):
            put(data, table+i*4+2, 1, 2)
    if mode == 'ilvu-bad-jump':
        put(data, base+starts[0]*2048+1031+180, 0x100000)
    elif mode == 'ilvu-bad-extent':
        put(data, base+starts[0]*2048+1031+34, 0x100000)
    elif mode == 'ilvu-bad-nav':
        data[base+starts[0]*2048+1024] = 1
    cadt = vts + number(data, vts+224)*2048
    put(data, cadt, 1, 2)
    put(data, cadt+4, 8+3*12-1)
    for n in range(3):
        entry = cadt+8+n*12
        put(data, entry, 1, 2)
        data[entry+3] = n+1
        put(data, entry+4, starts[0 if n == 0 else b_first] if n < 2 else starts[common])
        put(data, entry+8, starts[b_last]+len(units[order[b_last]])//2048-1 if n < 2 else cursor-1)
    expected = sum(len(unit) for unit in units)
    selected = [starts[i] for i in ([0,1,4,5,8] if multi else [0,2,4,6])]
    return bytes(data), expected, selected


def vm_fixture(original, mode):
    data = bytearray(variant(original, 'repeated-cell'))
    vts = data.index(b'DVDVIDEO-VTS')
    pgcit = vts + number(data, vts+204)*2048
    pgc = pgcit + number(data, pgcit+12)
    playback = pgc + number(data, pgc+232, 2)
    if mode == 'finite-still':
        data[playback+2] = 1
        return bytes(data), None, 'dvd_still_unsupported'
    if mode == 'terminal-still':
        data[playback+24+2] = 1
        return bytes(data), None, 'dvd_still_unsupported'
    # Two small PGCs in the original IFO allocation, linked by a real VM command.
    header = data[pgc:pgc+236]
    cell = data[playback:playback+24]
    pos = data[pgc+number(data, pgc+234, 2):][:4]
    put(data, pgcit, 2, 2)
    put(data, pgcit+4, 823)
    for n in range(2):
        entry = pgcit+8+n*8
        data[entry:entry+8] = bytes([0x81 if n == 0 else 1, 0, 0, 0])+ (24+n*400).to_bytes(4,'big')
        start = pgcit+24+n*400
        block = bytearray(400)
        block[:236] = header
        block[2:4] = bytes([1, 1])
        for offset, value in [(228,236),(230,252),(232,254),(234,278)]:
            put(block, offset, value, 2)
        # First PGC links to second; second exits back to the caller.
        put(block, 238, 1, 2)
        put(block, 242, 15, 2)
        block[244:252] = bytes.fromhex('2004000000000002' if n == 0 else '3001000000000000')
        block[252] = 1
        block[254:278] = cell
        block[278:282] = pos
        if mode == 'cell-command':
            put(block, 238, 0, 2)
            put(block, 240, 1, 2)
            block[254+3] = 1
        if mode == 'vm-loop' and n == 1:
            block[244:252] = bytes.fromhex('2004000000000001')
        if mode == 'vm-random' and n == 0:
            block[244:252] = bytes.fromhex('7800000100020000')
        if mode == 'vm-register-mode' and n == 0:
            block[244:252] = bytes.fromhex('5300000100000000')
        if mode == 'unused-random-pgc':
            if n == 0:
                block[244:252] = bytes.fromhex('3001000000000000')
            else:
                block[162] = 1
        if mode == 'used-random-pgc' and n == 0:
            block[162] = 1
        if mode == 'vm-pre-jump' and n == 0:
            put(block, 236, 1, 2)
            put(block, 238, 0, 2)
        data[start:start+400] = block
    ptt = vts+number(data, vts+200)*2048
    table = ptt+number(data, ptt+8)
    # Both aliases in the fixture refer to the same VTS title.
    count = (number(data, ptt+4)+1-number(data, ptt+8))//4
    for n in range(count):
        put(data, table+n*4, 1 if n == 0 else 2, 2)
        put(data, table+n*4+2, 1, 2)
    rejected = 'dvd_navigation_indeterminate' if mode in ('vm-loop','vm-random','used-random-pgc') else None
    return bytes(data), 3000 if mode in ('vm-pre-jump','unused-random-pgc','vm-register-mode') else 6000, rejected


def range_checks(bridge, title, expected_navs=None):
    url, size = bridge.url(title), title['size']
    head = urllib.request.urlopen(urllib.request.Request(url, method='HEAD'))
    assert head.status == 200 and int(head.headers['Content-Length']) == size
    whole = urllib.request.urlopen(url, timeout=30).read()
    assert len(whole) == size
    if expected_navs is not None:
        actual_navs = [number(whole, offset+45) for offset in range(0, size, 2048)
                       if whole[offset+38:offset+45] == bytes.fromhex('000001bf03d400')]
        assert actual_navs == expected_navs, (actual_navs, expected_navs)

    def read(start, length):
        end = min(size-1, start+length-1)
        r = urllib.request.urlopen(urllib.request.Request(url, headers={'Range': f'bytes={start}-{end}'}), timeout=30)
        assert r.status == 206 and r.headers['Content-Range'] == f'bytes {start}-{end}/{size}'
        value = r.read()
        assert value == whole[start:end+1]
        return value

    # 新 GET 必须取消旧 generation，且新请求仍返回固定视图。
    parsed = urlsplit(url)
    old = socket.socket()
    old.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    old.settimeout(5)
    old.connect((parsed.hostname, parsed.port))
    old.sendall(f'GET {parsed.path} HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-{size-1}\r\n\r\n'.encode())
    prefix = b''
    while b'\r\n\r\n' not in prefix:
        prefix += old.recv(1)
    assert b'206 Partial Content' in prefix
    read(size-8193, 8193)
    cancelled_bytes = 0
    try:
        while True:
            chunk = old.recv(65536)
            if not chunk:
                break
            cancelled_bytes += len(chunk)
    except ConnectionResetError:
        pass
    finally:
        old.close()
    assert cancelled_bytes < size, (cancelled_bytes, size)

    rng = random.Random(0x445644)
    for _ in range(60):
        start = rng.randrange(size)
        assert read(start, 8193) == read(start, 8193)
    rebuilt = b''.join(read(start, 16381) for start in range(0, size, 16381))
    assert rebuilt == whole
    # Concurrent HEADs and superseding GETs use the existing one-active-media policy.
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        lengths = list(pool.map(lambda _: int(urllib.request.urlopen(
            urllib.request.Request(url, method='HEAD')).headers['Content-Length']), range(12)))
    assert lengths == [size]*12
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers={'Range': f'bytes={size}-'}))
        raise AssertionError('Out-of-bounds Range accepted')
    except urllib.error.HTTPError as error:
        assert error.code == 416 and error.headers['Content-Range'] == f'bytes */{size}'
    return hashlib.sha256(whole).hexdigest()


def seek_check(player, url, output, mode):
    evidence = output / (mode+'-seek.json')
    script = output / (mode+'-seek.lua')
    script.write_text("""local utils = require('mp.utils')
local points = {}
mp.register_event('file-loaded', function()
    mp.add_timeout(0.2, function() mp.commandv('seek', '1.0', 'absolute+exact') end)
    mp.add_timeout(0.8, function()
        points[1] = mp.get_property_number('time-pos')
        mp.commandv('seek', '0.1', 'absolute+exact')
    end)
    mp.add_timeout(1.4, function()
        points[2] = mp.get_property_number('time-pos')
        local f = assert(io.open(OUTPUT, 'wb'))
        f:write(utils.format_json(points)); f:close()
        mp.commandv('quit')
    end)
end)
""".replace('OUTPUT', json.dumps(str(evidence).replace('\\','/'))), encoding='utf-8')
    result = subprocess.run([str(Path(player).resolve()), '--no-config', '--vo=null', '--ao=null',
        '--pause=yes', '--idle=no', '--keep-open=no', '--script='+str(script), url],
        capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
    (output / (mode+'-seek.log')).write_bytes(result.stdout+result.stderr)
    assert result.returncode == 0
    points = json.loads(evidence.read_text())
    assert abs(points[0]-1.0) < .2 and abs(points[1]-.1) < .2, points
    return points


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('iso')
    parser.add_argument('--helper', required=True)
    parser.add_argument('--player', required=True)
    args = parser.parse_args()
    with open(args.iso, 'rb') as source:
        original = source.read(32*1024*1024)
    output = Path('build/dvd-navigation/fixtures').resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for mode in ['ilvu', 'ilvu-multi-vobu', 'ilvu-angle-still', 'ilvu-bad-jump', 'ilvu-bad-extent', 'ilvu-bad-nav',
                 'cross-pgc', 'cell-command', 'unused-random-pgc', 'used-random-pgc', 'vm-register-mode', 'vm-pre-jump', 'vm-loop', 'vm-random', 'finite-still', 'terminal-still']:
        if mode.startswith('ilvu'):
            prefix, expected, expected_navs = ilvu_fixture(original, mode)
            rejected = (None if mode in ('ilvu','ilvu-multi-vobu') else
                        'dvd_still_unsupported' if mode == 'ilvu-angle-still' else 'invalid_dvd_navigation')
            duration = None
        else:
            prefix, duration, rejected = vm_fixture(original, mode)
            expected = None
            expected_navs = None
        server = IsoServer(args.iso, prefix)
        server.version = mode
        bridge = None
        try:
            try:
                bridge = Bridge(args.helper, args.iso, output / mode, server.url)
            except RuntimeError as error:
                assert rejected == error.args[0]['code'], error
                results.append(dict(mode=mode, rejected=error.args[0]['code']))
                continue
            assert rejected is None
            title = bridge.ready['titles'][0]
            if expected is not None:
                assert title['size'] == expected, (title, expected)
            if duration is not None:
                assert title['durationMs'] == duration, (mode, title)
            digest = range_checks(bridge, title, expected_navs)
            player = subprocess.run([str(Path(args.player).resolve()), '--no-config', '--vo=null', '--ao=null',
                '--cache=no', '--speed=4', '--idle=no', '--keep-open=no', bridge.url(title)],
                capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
            log = (player.stdout + player.stderr).decode(errors='replace')
            (output / (mode+'.log')).write_text(log, encoding='utf-8')
            assert player.returncode == 0 and 'VO:' in log and 'AO:' in log
            if mode in ('ilvu', 'ilvu-multi-vobu'):
                assert 'desynchronisation' not in log and 'Invalid audio PTS' not in log
            seek_points = seek_check(args.player, bridge.url(title), output, mode) if mode.startswith('ilvu') else None
            results.append(dict(mode=mode, logicalBytes=title['size'], sha256=digest, rangeChecks=True, decoded=True, seekPoints=seek_points))
        finally:
            if bridge:
                bridge.close()
            server.close()
    (output / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(json.dumps(results), flush=True)


if __name__ == '__main__':
    main()
