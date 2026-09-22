import json, os, sys
d = sys.argv[1]
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
base = os.path.join(project_root, "stream_path_data", "cache", "iso_benchmarks", d)
summ = json.load(open(os.path.join(base, "iso-performance.json"), encoding="utf-8"))
met = json.load(open(os.path.join(base, "iso-bridge-metrics.json"), encoding="utf-8"))
print("status:", summ.get("status"), "| seek:", summ.get("seekRecoveryMs"), "| switch:", summ.get("titleSwitchGapMs"))
print("timings:", summ.get("timings"))
print("final:", met.get("bridge",{}).get("final"), "| errors:", met.get("errors"), "| req:", met.get("network",{}).get("requestCount"), "| playbackReq:", met.get("playbackRequests"))
evs = [json.loads(l) for l in open(os.path.join(base, "iso-performance-events.jsonl"), encoding="utf-8") if l.strip()]
for e in evs:
    print(" ", e.get("event"), "pos", e.get("playlist_pos"), "serial", e.get("restart_serial"), "t=%.2f" % e.get("time", -1))
