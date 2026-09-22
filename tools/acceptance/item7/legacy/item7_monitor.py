import subprocess, time, json, os, shutil, sys
print("已停用：请使用 tools/acceptance/item7/item7_round.py，它会在注入前启动证据镜像。")
sys.exit(2)
round_name = sys.argv[1]
root = r"C:\Users\YX\Documents\StreamPathProject\stream_path_data\cache\iso_temp"
ev = os.path.join(os.path.dirname(os.path.abspath(__file__)), "item7_evidence", round_name)
os.makedirs(ev, exist_ok=True)
# locate newest session dir
dirs = [d for d in os.listdir(root) if d.startswith("iso_")]
if not dirs:
    print("no session dir"); sys.exit(1)
sd = os.path.join(root, sorted(dirs)[-1])
deadline = time.time() + 240
while time.time() < deadline:
    out = subprocess.run(["tasklist"], capture_output=True).stdout.lower()
    if b"mpv.exe" not in out:
        break
    time.sleep(2)
# MPV gone (or timeout): tight-loop snapshot session dir before cleanup
for _ in range(40):
    try:
        if os.path.isdir(sd):
            for fn in os.listdir(sd):
                src = os.path.join(sd, fn)
                if os.path.isfile(src):
                    try: shutil.copy2(src, os.path.join(ev, fn))
                    except Exception: pass
            break
    except Exception:
        pass
    time.sleep(0.15)
evf = os.path.join(ev, "iso-performance-events.jsonl")
if os.path.exists(evf):
    evs = [json.loads(l) for l in open(evf, encoding="utf-8") if l.strip()]
    print("events:", [(e.get("event"), e.get("playlist_pos")) for e in evs])
jr = os.path.join(ev, "iso-progress.jsonl")
if os.path.exists(jr):
    print("journal:", [json.loads(l).get("outcome") for l in open(jr, encoding="utf-8") if l.strip()])
mt = os.path.join(ev, "iso-bridge-metrics.json")
if os.path.exists(mt):
    m = json.load(open(mt, encoding="utf-8"))
    print("final:", m.get("bridge",{}).get("final"), "| errors:", m.get("errors"), "| req:", m.get("network",{}).get("requestCount"))
print("session still exists:", os.path.isdir(sd))
print("evidence saved to:", ev)
