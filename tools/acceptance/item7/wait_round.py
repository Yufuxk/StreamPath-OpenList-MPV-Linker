import subprocess, time, json, os, sys
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
root = os.path.join(project_root, "stream_path_data", "cache", "iso_benchmarks")
before = set(os.listdir(root))
deadline = time.time() + 260
while time.time() < deadline:
    out = subprocess.run(["tasklist"], capture_output=True).stdout.lower()
    if b"mpv.exe" not in out:
        print("MPV exited"); break
    time.sleep(8)
else:
    print("TIMEOUT waiting mpv exit"); sys.exit(1)
for _ in range(10):
    time.sleep(2)
    new = set(os.listdir(root)) - before
    if new:
        d = sorted(new)[-1]
        perf_p = os.path.join(root, d, "iso-performance.json")
        met_p = os.path.join(root, d, "iso-bridge-metrics.json")
        if os.path.exists(perf_p) and os.path.exists(met_p):
            summ = json.load(open(perf_p, encoding="utf-8"))
            met = json.load(open(met_p, encoding="utf-8"))
            print("archive:", d)
            print("status:", summ.get("status"), "| seek:", summ.get("seekRecoveryMs"), "| switch:", summ.get("titleSwitchGapMs"))
            print("final:", met.get("bridge", {}).get("final"), "| errors:", met.get("errors"), "| req:", met.get("network", {}).get("requestCount"))
            sys.exit(0)
print("no new archive detected")
