"""汇总隔离详情页 Profile 原始记录，不将 FrameTiming 换算为 FPS。"""
import argparse
import json
import math
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    groups = {}
    for path in args.directory.glob("*-r*.json"):
        if path.name.endswith("-process.json"):
            continue
        label, count, run = path.stem.split("-")
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
        process = json.loads(path.with_name(f"{path.stem}-process.json").read_text(encoding="utf-8-sig"))
        group = groups.setdefault((int(count), label), {"runs": [], "phases": {}, "operations": []})
        group["runs"].append({"run": run, "window": [raw.get("windowWidth"), raw.get("windowHeight")],
                              "dpr": raw["dpr"], "refreshRate": raw.get("refreshRate"),
                              "peakPrivateBytes": max(p["privateBytes"] for p in process),
                              "peakWorkingSet": max(p["workingSet"] for p in process)})
        group["operations"].extend(raw["operations"])
        for frame in raw["frames"]:
            group["phases"].setdefault(frame["phase"], []).append(frame)
    rows = []
    for (count, label), group in sorted(groups.items()):
        summary = {"count": count, "label": label, "runs": group["runs"], "phases": {}}
        summary["maxLiveCards"] = max(op["liveCards"] for op in group["operations"])
        summary["maxLiveImages"] = max(op["liveImages"] for op in group["operations"])
        summary["maxImageCacheBytes"] = max(op["imageCacheBytes"] for op in group["operations"])
        for phase, frames in group["phases"].items():
            ui = [f["uiUs"] for f in frames]
            raster = [f["rasterUs"] for f in frames]
            total = [f["totalUs"] for f in frames]
            summary["phases"][phase] = {"frames": len(frames), "uiP50Us": percentile(ui, .5),
                "uiP95Us": percentile(ui, .95), "uiP99Us": percentile(ui, .99), "uiMaxUs": max(ui),
                "rasterP50Us": percentile(raster, .5), "rasterP95Us": percentile(raster, .95),
                "rasterP99Us": percentile(raster, .99), "rasterMaxUs": max(raster),
                "totalSpanP95Us": percentile(total, .95), "totalSpanMaxUs": max(total),
                "uiOver16667Us": sum(v > 16667 for v in ui),
                "rasterOver16667Us": sum(v > 16667 for v in raster)}
        rows.append(summary)
    args.directory.joinpath("summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# Windows Profile 合成详情页基准", "", "固定脚本，每组按运行记录汇总；FrameTiming 不代表显示帧间隔。峰值进程内存包含夹具准备，非 Dart heap。", "",
             "| 集数 | 版本 | 操作 | 帧数 | UI P95 / 最大 ms | Raster P95 / 最大 ms | 超 16.67ms UI / Raster |",
             "|---:|---|---|---:|---|---|---|"]
    for row in rows:
        for phase, v in row["phases"].items():
            if phase == "idle":
                continue
            lines.append(f'| {row["count"]} | {row["label"]} | {phase} | {v["frames"]} | '
                         f'{v["uiP95Us"]/1000:.2f} / {v["uiMaxUs"]/1000:.2f} | '
                         f'{v["rasterP95Us"]/1000:.2f} / {v["rasterMaxUs"]/1000:.2f} | '
                         f'{v["uiOver16667Us"]} / {v["rasterOver16667Us"]} |')
    args.directory.joinpath("summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Summarized {sum(len(row['runs']) for row in rows)} runs in {args.directory}")


if __name__ == "__main__":
    main()
