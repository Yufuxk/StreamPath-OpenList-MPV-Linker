"""Summarize five paired menu runs; round zero is warm-up only."""
import json
import math
import pathlib
import statistics


def timings(samples):
    restarts = [s for s in samples if s['event'] == 'playback-restart']
    result = {'startup': restarts[0]['ms']}
    for sample in samples:
        if sample['event'] != 'command':
            continue
        args = sample['detail']['args']
        if args in (['discnav', 'down'], ['discnav', 'popup']):
            continue
        name = ' '.join(args)
        restart = next(s for s in restarts if s['ms'] >= sample['ms'])
        result[name] = restart['ms'] - sample['ms']
    return result


def stats(values):
    ordered = sorted(values)
    return {'median': statistics.median(ordered),
            'p95': ordered[math.ceil(len(ordered) * .95) - 1],
            'max': max(ordered)}


def summarize(root):
    runs = {'old': [], 'new': []}
    for mode in runs:
        for number in range(1, 6):
            path = root / f'menu-paired-{number}-{mode}'
            metrics = json.loads((path / 'session/iso-bridge-metrics.json').read_text())
            menu = json.loads((path / 'menu.json').read_text())
            summary = json.loads((path / 'summary.json').read_text())
            assert metrics['bridge']['final'] and not metrics['virtualDisc']['failed']
            cache = metrics['playbackCache']
            runs[mode].append({
                'round': number, 'timings': timings(menu['samples']),
                'requests': summary['server']['requests'],
                'bytes': summary['server']['bytes'],
                'readMs': metrics['virtualDisc']['readUs'] / 1000,
                'refetchBlocks': cache['refetchCount'],
                'capacityBytes': cache['capacityBytes'],
                'prefetchActivePeak': cache['prefetchActivePeak'],
            })
    timing_stats = {mode: {name: stats([r['timings'][name] for r in rows])
                          for name in rows[0]['timings']}
                    for mode, rows in runs.items()}
    seek_pass = all(new['timings'][name] <= old['timings'][name]
                    for old, new in zip(runs['old'], runs['new'])
                    for name in old['timings'] if name.startswith('seek '))
    result = {'schema': 1, 'environment': 'local Range, 20 ms per GET, headless',
              'runs': runs, 'timingStatsMs': timing_stats,
              'fixedSeekNonRegression': seek_pass,
              'fewerRequestsEveryPair': all(n['requests'] < o['requests']
                                           for o, n in zip(runs['old'], runs['new']))}
    destination = root / 'menu-cache-paired-summary.json'
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    summarize(pathlib.Path('build'))
