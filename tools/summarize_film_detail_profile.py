"""汇总隔离详情页 Profile 原始记录，不将 FrameTiming 换算为 FPS。"""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
from statistics import mean


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def frame_statistics(frame_runs):
    metrics = {"ui": [], "raster": [], "totalSpan": [], "wait": []}
    over_budget = {"ui": 0, "raster": 0, "either": 0}
    longest = {"ui": 0, "raster": 0, "either": 0}
    budgeted_frames = 0
    numbered_frames = 0
    for frames, refresh_rate in frame_runs:
        budget = 1_000_000 / refresh_rate if refresh_rate else None
        streak = dict.fromkeys(longest, 0)
        previous = None
        for frame in sorted(frames, key=lambda item: item["startUs"]):
            for metric, field in (("ui", "uiUs"), ("raster", "rasterUs"),
                                  ("totalSpan", "totalUs"), ("wait", "waitUs")):
                if field in frame:
                    metrics[metric].append(frame[field])
            if budget is None:
                continue
            budgeted_frames += 1
            number = frame.get("number", -1)
            numbered_frames += number >= 0
            if previous is None or number != previous + 1:
                streak = dict.fromkeys(longest, 0)
            ui = frame["uiUs"] > budget
            raster = frame["rasterUs"] > budget
            for metric, over in (("ui", ui), ("raster", raster), ("either", ui or raster)):
                over_budget[metric] += over
                streak[metric] = streak[metric] + 1 if over else 0
                if number >= 0:
                    longest[metric] = max(longest[metric], streak[metric])
            previous = number if number >= 0 else None
    result = {"frames": len(metrics["ui"]), "budgetedFrames": budgeted_frames}
    for metric, values in metrics.items():
        if values:
            result.update({f"{metric}MeanUs": mean(values),
                           f"{metric}P50Us": percentile(values, .50),
                           f"{metric}P95Us": percentile(values, .95),
                           f"{metric}P99Us": percentile(values, .99),
                           f"{metric}MaxUs": max(values)})
    for metric, count in over_budget.items():
        result[f"{metric}OverBudget"] = count if budgeted_frames else None
        result[f"{metric}OverBudgetRatio"] = count / budgeted_frames if budgeted_frames else None
        result[f"{metric}LongestOverBudget"] = (
            longest[metric] if budgeted_frames and numbered_frames == budgeted_frames else None
        )
    for metric in ("ui", "raster"):
        result[f"{metric}Over16667Us"] = sum(value > 16667 for value in metrics[metric])
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    groups = {}
    for path in sorted(args.directory.glob("*-r*.json")):
        if path.name.endswith("-process.json"):
            continue
        label, count, run = path.stem.split("-")
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
        process = json.loads(path.with_name(f"{path.stem}-process.json").read_text(encoding="utf-8-sig"))
        rate = raw.get("refreshRate")
        phases = defaultdict(list)
        for frame in raw["frames"]:
            phases[frame["phase"]].append(frame)
        group = groups.setdefault((int(count), label), {"runs": [], "phases": defaultdict(list), "operations": []})
        group["runs"].append({"run": run, "window": [raw.get("windowWidth"), raw.get("windowHeight")],
                              "dpr": raw["dpr"], "refreshRate": rate,
                              "peakPrivateBytes": max(p["privateBytes"] for p in process),
                              "peakWorkingSet": max(p["workingSet"] for p in process),
                              "phases": {phase: frame_statistics([(frames, rate)])
                                         for phase, frames in phases.items()}})
        group["operations"].extend(raw["operations"])
        for phase, frames in phases.items():
            group["phases"][phase].append((frames, rate))
    rows = []
    for (count, label), group in sorted(groups.items()):
        summary = {"count": count, "label": label, "runs": group["runs"], "phases": {}}
        summary["maxLiveCards"] = max(op["liveCards"] for op in group["operations"])
        summary["maxLiveImages"] = max(op["liveImages"] for op in group["operations"])
        summary["maxImageCacheBytes"] = max(op["imageCacheBytes"] for op in group["operations"])
        summary["phases"] = {phase: frame_statistics(frame_runs)
                             for phase, frame_runs in group["phases"].items()}
        rows.append(summary)
    args.directory.joinpath("summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# Windows Profile 合成详情页基准", "", "固定脚本，每组按运行记录汇总；FrameTiming 不代表显示帧间隔。峰值进程内存包含夹具准备，非 Dart heap。", "",
             "| 集数 | 版本 | 操作 | 帧数 | UI P95 / 最大 ms | Raster P95 / 最大 ms | 超预算 UI / Raster |",
             "|---:|---|---|---:|---|---|---|"]
    for row in rows:
        for phase, v in row["phases"].items():
            if phase == "idle":
                continue
            lines.append(f'| {row["count"]} | {row["label"]} | {phase} | {v["frames"]} | '
                         f'{v["uiP95Us"]/1000:.2f} / {v["uiMaxUs"]/1000:.2f} | '
                         f'{v["rasterP95Us"]/1000:.2f} / {v["rasterMaxUs"]/1000:.2f} | '
                         f'{v["uiOverBudget"]} / {v["rasterOverBudget"]} |')
    args.directory.joinpath("summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Summarized {sum(len(row['runs']) for row in rows)} runs in {args.directory}")


if __name__ == "__main__":
    main()
