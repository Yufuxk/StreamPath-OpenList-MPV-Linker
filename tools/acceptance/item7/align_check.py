import json, os, re, glob, sys
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
root = os.path.join(project_root, "stream_path_data", "cache", "iso_benchmarks")
rows = []
anon_pat = re.compile(r"(http|://|192\.168|@|\\|[A-Za-z]:\\|\.iso|\.m2ts|token|auth)", re.I)
for d in sorted(glob.glob(os.path.join(root, "iso_*"))):
    name = os.path.basename(d)
    try:
        met = json.load(open(os.path.join(d, "iso-bridge-metrics.json"), encoding="utf-8"))
        summ = json.load(open(os.path.join(d, "iso-performance.json"), encoding="utf-8"))
        events = [json.loads(l) for l in open(os.path.join(d, "iso-performance-events.jsonl"), encoding="utf-8") if l.strip()]
    except Exception as e:
        rows.append((name, "READ_FAIL", str(e))); continue
    issues = []
    if met.get("version") != 2: issues.append("metrics.version!=2")
    if met.get("bridge", {}).get("final") is not True: issues.append("bridge.final!=true")
    if met.get("errors"): issues.append("metrics.errors=%s" % met["errors"])
    if summ.get("errors"): issues.append("summary.errors=%s" % summ["errors"])
    if summ.get("status") != "complete": issues.append("status!=complete")
    # recompute seek/switch from events
    seek, sw = [], []
    pend_s = pend_e = None
    for ev in events:
        n = ev.get("event")
        if n == "seek-start": pend_s = ev
        elif n == "title-eof": pend_e = ev
        elif n == "stable-playback":
            if pend_s and pend_s.get("playlist_pos") == ev.get("playlist_pos") and ev["time"] >= pend_s["time"]:
                seek.append(round((ev["time"]-pend_s["time"])*1000)); pend_s = None
            if pend_e and pend_e.get("playlist_pos") != ev.get("playlist_pos") and ev["time"] >= pend_e["time"]:
                sw.append(round((ev["time"]-pend_e["time"])*1000)); pend_e = None
    if seek != summ.get("seekRecoveryMs"): issues.append("seek mismatch: summary=%s recomputed=%s" % (summ.get("seekRecoveryMs"), seek))
    if sw != summ.get("titleSwitchGapMs"): issues.append("switch mismatch: summary=%s recomputed=%s" % (summ.get("titleSwitchGapMs"), sw))
    # cross-process: mpvLaunchToStablePlaybackMs vs first stable event
    st = [e for e in events if e.get("event") == "stable-playback"]
    if st:
        first_stable_ms = st[0]["time"]*1000
        m = summ.get("timings", {}).get("mpvLaunchToStablePlaybackMs")
        if m is not None:
            delta = m - first_stable_ms
            if abs(delta) > 500: issues.append("mpvLaunch->stable delta=%.0fms" % delta)
    # switch continuity: every title-eof followed by next title stable
    pl_eofs = [e.get("playlist_pos") for e in events if e.get("event") == "title-eof"]
    pl_stables = [e.get("playlist_pos") for e in st]
    # anonymity scan of all three artifacts
    for fn in ("iso-bridge-metrics.json", "iso-performance.json", "iso-performance-events.jsonl"):
        txt = open(os.path.join(d, fn), encoding="utf-8").read()
        hits = anon_pat.findall(txt)
        if hits: issues.append("ANON suspicious in %s: %s" % (fn, sorted(set(hits))))
    # event key whitelist
    for ev in events:
        extra = set(ev.keys()) - {"event", "time", "playlist_pos", "restart_serial"}
        if extra: issues.append("event extra keys %s" % extra); break
    rows.append((name, "OK" if not issues else "ISSUES", "; ".join(issues) if issues else
                 "seek=%s switch=%s stable_n=%d req=%d redirect=%d reuse=%d" % (summ.get("seekRecoveryMs"), summ.get("titleSwitchGapMs"), len(st), met.get("network",{}).get("requestCount"), met.get("network",{}).get("redirectCount"), met.get("network",{}).get("resolvedUrlReuseCount"))))
for r in rows: print(" | ".join(str(x) for x in r))
