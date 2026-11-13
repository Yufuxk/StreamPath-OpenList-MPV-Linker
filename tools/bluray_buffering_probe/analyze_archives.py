"""只读汇总光盘诊断归档；输出仅含白名单指标。"""

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def summarize(directory):
    metrics_file = directory / "iso-bridge-metrics.json"
    metrics = json.loads(metrics_file.read_text(encoding="utf-8-sig"))
    event_file = next(directory.glob("*events.jsonl"))
    events = [
        json.loads(line)
        for line in event_file.read_text(encoding="utf-8-sig").splitlines()
        if line.strip()
    ]
    spans = []
    pending = None
    duplicate_starts = 0
    unpaired_ends = 0
    last_transition = None
    for event in events:
        name = event.get("event")
        if name in {"start-file", "file-loaded", "seek", "seek-start"}:
            last_transition = event["time"]
        if name == "cache-pause-start":
            duplicate_starts += pending is not None
            pending = (event, last_transition)
        elif name == "cache-pause-end":
            if pending is None:
                unpaired_ends += 1
                continue
            start, transition = pending
            duration_ms = (event["time"] - start["time"]) * 1000
            if duration_ms < 0:
                raise ValueError("event clock moved backward")
            spans.append(
                {
                    "startSeconds": start["time"],
                    "durationMs": round(duration_ms, 3),
                    "positionSeconds": start.get("position"),
                    "mediaDurationSeconds": start.get("duration"),
                    "seeking": start.get("seeking"),
                    "menu": start.get("menu"),
                    "cacheDurationSeconds": start.get("cache_duration"),
                    "snapshotAgeMs": start.get("metrics_age_ms"),
                    "snapshotForwardBytes": start.get("forward_bytes"),
                    "within2sOfTransition": transition is not None
                    and start["time"] - transition <= 2,
                }
            )
            pending = None
    durations = sorted(span["durationMs"] for span in spans)
    network = metrics["playbackNetwork"]
    cache = metrics["playbackCache"]
    result = {
        "session": directory.name,
        "mode": "menu" if "menu" in directory.name else "title",
        "eventElapsedSeconds": events[-1].get("time") if events else None,
        "pairedPauseCount": len(spans),
        "pauseTotalMs": round(sum(durations), 3),
        "pauseMedianMs": statistics.median(durations) if durations else None,
        "pauseP95Ms": durations[math.ceil(len(durations) * 0.95) - 1]
        if durations else None,
        "pauseMaxMs": max(durations) if durations else None,
        "pausesGe100ms": sum(value >= 100 for value in durations),
        "seekingPauseCount": sum(span["seeking"] is True for span in spans),
        "transitionAdjacentPauseCount": sum(span["within2sOfTransition"] for span in spans),
        "unpairedStartCount": int(pending is not None),
        "duplicateStartCount": duplicate_starts,
        "unpairedEndCount": unpaired_ends,
        "truncated": any("truncat" in str(e.get("event", "")) for e in events),
        "playbackNetwork": {
            key: network.get(key) for key in (
                "requestCount", "redirectCount", "responseHeaderLatencyUsTotal",
                "responseBodyActiveUsTotal", "remoteBodyBytes",
                "remoteTransferWallClockUs", "concurrentTransferWallClockUs",
            )
        },
        "playbackCache": {
            key: cache.get(key) for key in (
                "requestCount", "cacheMissCount", "foregroundFetchBytes",
                "prefetchFetchBytes", "foregroundLoadingWaitCount",
                "foregroundLoadingWaitUsTotal", "foregroundLoadingWaitUsMax",
                "capacityBytes", "residentBytes", "evictionCount", "refetchCount",
                "configuredPrefetchBlocks", "cancelledPrefetchBytes",
                "prefetchUnusedBytes", "prefetchPendingGapUsMax",
            )
        },
        "pauseSpans": spans,
        "sourceHashes": {
            file.name: hashlib.sha256(file.read_bytes()).hexdigest()
            for file in (metrics_file, event_file)
        },
    }
    count = network["requestCount"]
    result["meanHeaderMs"] = network["responseHeaderLatencyUsTotal"] / count / 1000 if count else None
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive_root", type=Path)
    parser.add_argument("--latest", type=int, default=4)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    directories = sorted(
        (path for path in args.archive_root.iterdir() if path.is_dir()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )[:args.latest]
    results = [summarize(path) for path in directories]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps([
        {key: item[key] for key in (
            "session", "pairedPauseCount", "pauseTotalMs", "pauseMaxMs",
            "pausesGe100ms", "meanHeaderMs", "unpairedStartCount",
        )} for item in results
    ]))


if __name__ == "__main__":
    main()
