"""Read-only structural DVD variants; all changes exist only in the loopback fixture."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import urllib.request

from validate_dvd_iso import Bridge, IsoServer


def number(data, offset, size=4):
    return int.from_bytes(data[offset:offset+size], 'big')


def put(data, offset, value, size=4):
    data[offset:offset+size] = value.to_bytes(size, 'big')


def variant(original, mode):
    data = bytearray(original)
    vmg = data.index(b'DVDVIDEO-VMG')
    vts = data.index(b'DVDVIDEO-VTS')
    titles = vmg + number(data, vmg + 196) * 2048
    assert number(data, titles, 2) == 1, 'This fixture requires the supplied single-title sample'
    put(data, titles, 2, 2)
    put(data, titles + 4, 31)
    data[titles+20:titles+32] = data[titles+8:titles+20]
    pgcit = vts + number(data, vts + 204) * 2048
    pgc = pgcit + number(data, pgcit + 12)
    program = pgc + number(data, pgc + 230, 2)
    playback = pgc + number(data, pgc + 232, 2)
    positions = pgc + number(data, pgc + 234, 2)
    admap = vts + number(data, vts + 228) * 2048
    navs = [number(data, admap + i) for i in range(4, number(data, admap) + 1, 4)]
    first = number(data, playback + 8)
    start = navs.index(first)
    last = navs[start+6] - 1
    cell = bytearray(data[playback:playback+24])
    cell[:4] = bytes(4)
    cell[4:8] = bytes([0, 0, 3, 0xc0])
    put(cell, 8, first)
    put(cell, 12, first)
    put(cell, 16, navs[start+5])
    put(cell, 20, last)
    data[playback:playback+24] = cell
    data[pgc+3] = 1
    data[pgc+4:pgc+8] = cell[4:8]
    programs = data[pgc+2]
    data[program:program+programs] = bytes([1]) * programs
    if mode == 'repeated-cell':
        data[pgc+3] = 2
        data[pgc+4:pgc+8] = bytes([0, 0, 6, 0xc0])
        data[playback+24:playback+48] = cell
        data[positions+4:positions+8] = data[positions:positions+4]
        data[program+1:program+programs] = bytes([2]) * (programs-1)
    elif mode == 'first-angle':
        data[titles+9] = data[titles+21] = 2
        data[pgc+3] = 2
        data[playback] = 0x50
        second = bytearray(cell)
        second[0] = 0xd0
        data[playback+24:playback+48] = second
        data[positions+4:positions+8] = data[positions:positions+4]
    elif mode == 'unsupported-interactive':
        data[playback+2] = 255
    return bytes(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('iso')
    parser.add_argument('--helper', default='build/dvd-support/native/streampath_iso_bridge.exe')
    parser.add_argument('--player', required=True)
    args = parser.parse_args()
    with open(args.iso, 'rb') as source:
        original = source.read(32 * 1024 * 1024)
    output = Path('build/dvd-support/variants').resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for mode in ['two-titles', 'repeated-cell', 'first-angle', 'unsupported-interactive']:
        server = IsoServer(args.iso, variant(original, mode))
        server.version = mode
        bridge = None
        try:
            try:
                bridge = Bridge(args.helper, args.iso, output / mode, server.url)
            except RuntimeError as failure:
                if mode != 'unsupported-interactive' or failure.args[0].get('code') != 'unsupported_dvd_title':
                    raise
                results.append(dict(mode=mode, rejected=True))
                continue
            assert len(bridge.ready['titles']) == 2
            expected_duration = 6000 if mode == 'repeated-cell' else 3000
            assert all(title['durationMs'] == expected_duration for title in bridge.ready['titles'])
            playlist = output / (mode + '.m3u8')
            playlist.write_text('#EXTM3U\n' + '\n'.join(bridge.url(t) for t in bridge.ready['titles']) + '\n')
            player = subprocess.run([str(Path(args.player).resolve()), '--no-config', '--vo=null', '--ao=null',
                '--cache=no', '--speed=10', '--idle=no', '--keep-open=no', '--playlist=' + str(playlist)],
                capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
            log = player.stdout.decode(errors='replace') + player.stderr.decode(errors='replace')
            (output / (mode + '.log')).write_text(log, encoding='utf-8')
            assert player.returncode == 0 and log.count('Playing:') == 2 and 'VO:' in log
            # The second half of a repeated cell must advance its timestamp epoch.
            if mode == 'repeated-cell':
                title = bridge.ready['titles'][0]
                midpoint = title['size'] // 2
                for start in [0, midpoint, midpoint+1]:
                    request = urllib.request.Request(bridge.url(title), headers={'Range': f'bytes={start}-{start+65535}'})
                    assert len(urllib.request.urlopen(request, timeout=10).read()) == 65536
            results.append(dict(mode=mode, titles=2, durationMs=expected_duration,
                                automaticPlaylistAdvance=True, playerExitCode=player.returncode))
        finally:
            if bridge:
                bridge.close()
            server.close()
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results), flush=True)


if __name__ == '__main__':
    main()
