import argparse
import json
import os
import shutil
import subprocess
import threading
import time
import uuid

from acceptance_control import atomic_write_json, read_json


HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
RUNTIME = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "sp_accept")
ROOT = os.path.join(PROJECT_ROOT, "stream_path_data", "cache", "iso_temp")
BENCH = os.path.join(PROJECT_ROOT, "stream_path_data", "cache", "iso_benchmarks")
CONTROL = os.path.join(RUNTIME, "proxy_control.json")
STATUS = os.path.join(RUNTIME, "proxy_status.json")
LOG = os.path.join(RUNTIME, "proxy_log.jsonl")
KEY_SCRIPT = os.path.join(HERE, "mpvkey2.ps1")


def copy_file(source, destination):
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    temp = destination + ".tmp"
    try:
        shutil.copy2(source, temp)
        os.replace(temp, destination)
    except (FileNotFoundError, PermissionError, OSError):
        try:
            if os.path.exists(temp):
                os.remove(temp)
        except OSError:
            pass


class EvidenceMirror:
    def __init__(self, evidence_dir):
        self.evidence_dir = evidence_dir
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        try:
            initial = [name for name in os.listdir(ROOT) if name.startswith("iso_")]
        except OSError:
            initial = []
        self.initial_names = set(initial)
        self.session_names = set()
        if initial:
            newest = max(initial, key=lambda name: os.path.getmtime(os.path.join(ROOT, name)))
            self.session_names.add(newest)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=3)
        self.capture_once()

    def capture_once(self):
        try:
            names = [name for name in os.listdir(ROOT) if name.startswith("iso_")]
        except OSError:
            return
        self.session_names.update(set(names) - self.initial_names)
        for name in self.session_names:
            session_dir = os.path.join(ROOT, name)
            if not os.path.isdir(session_dir):
                continue
            try:
                files = os.listdir(session_dir)
            except OSError:
                continue
            for filename in files:
                source = os.path.join(session_dir, filename)
                if os.path.isfile(source):
                    copy_file(source, os.path.join(self.evidence_dir, "live", name, filename))

    def _run(self):
        while not self.stop_event.is_set():
            self.capture_once()
            self.stop_event.wait(0.2)


def parse_log_from(offset):
    if not os.path.exists(LOG):
        return []
    rows = []
    with open(LOG, "r", encoding="utf-8") as stream:
        stream.seek(offset)
        for line in stream:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def is_media_get(row):
    value = row.get("range", "")
    return row.get("method") == "GET" and value and "bytes=0-0" not in value


def send_j(mpv_pid):
    result = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", KEY_SCRIPT,
         "-key", "J", "-targetPid", str(mpv_pid)],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError("J 发送失败: %s" % (result.stdout + result.stderr).strip())
    print(result.stdout.strip(), flush=True)


def find_mpv_pid(explicit_pid):
    if explicit_pid:
        return explicit_pid
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "@(Get-Process mpv -ErrorAction SilentlyContinue).Id -join ','"],
        capture_output=True, text=True, timeout=10, check=True,
    )
    values = [value for value in result.stdout.strip().split(",") if value]
    if len(values) != 1:
        raise RuntimeError("必须恰好存在一个 mpv.exe，当前 PID: %s" % (values or "无"))
    return int(values[0])


def wait_for(predicate, timeout, interval=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return None


def current_status():
    try:
        return read_json(STATUS)
    except (OSError, json.JSONDecodeError):
        return None


def snapshot_benchmark(evidence_dir, started_at):
    try:
        candidates = [os.path.join(BENCH, name) for name in os.listdir(BENCH)]
        candidates = [path for path in candidates if os.path.isdir(path) and os.path.getmtime(path) >= started_at - 5]
    except OSError:
        return
    if not candidates:
        return
    source_dir = max(candidates, key=os.path.getmtime)
    for filename in ("iso-performance-events.jsonl", "iso-bridge-metrics.json"):
        source = os.path.join(source_dir, filename)
        if os.path.isfile(source):
            copy_file(source, os.path.join(evidence_dir, "archive", filename))


def collect_outcomes(evidence_dir):
    outcomes = []
    events = []
    for base, _, files in os.walk(evidence_dir):
        if "iso-progress.jsonl" in files:
            try:
                with open(os.path.join(base, "iso-progress.jsonl"), encoding="utf-8") as stream:
                    outcomes.extend(json.loads(line).get("outcome") for line in stream if line.strip())
            except (OSError, json.JSONDecodeError):
                pass
        if "iso-performance-events.jsonl" in files:
            try:
                with open(os.path.join(base, "iso-performance-events.jsonl"), encoding="utf-8") as stream:
                    events.extend(json.loads(line).get("event") for line in stream if line.strip())
            except (OSError, json.JSONDecodeError):
                pass
    return sorted(set(outcomes)), sorted(set(events))


def main():
    parser = argparse.ArgumentParser(description="第7条播放中故障单次确定性验收")
    parser.add_argument("round_name")
    parser.add_argument("mode", choices=("midstream_cut", "midstream_cut_body", "remote_changed"))
    parser.add_argument("--mpv-pid", type=int, default=0)
    parser.add_argument("--route-timeout", type=int, default=60)
    parser.add_argument("--hit-timeout", type=int, default=300)
    parser.add_argument("--seek-interval", type=int, default=10)
    parser.add_argument("--settle", type=int, default=60)
    args = parser.parse_args()

    evidence_dir = os.path.join(RUNTIME, "item7_evidence", args.round_name)
    if os.path.isdir(evidence_dir) and os.listdir(evidence_dir):
        raise RuntimeError("证据目录已存在且非空: %s" % evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)
    started_at = time.time()
    mpv_pid = find_mpv_pid(args.mpv_pid)
    log_offset = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    mirror = EvidenceMirror(evidence_dir)
    mirror.start()  # 必须早于首个 J，持续镜像 journal 和事件流。
    arm_id = "%s-%s" % (args.round_name, uuid.uuid4().hex[:12])
    result = {
        "round": args.round_name, "mode": args.mode, "arm_id": arm_id,
        "mpv_pid": mpv_pid, "started_at": started_at, "route_verified": False,
        "injection_hit": False, "settle_seconds": args.settle,
    }

    try:
        print("[1/4] 验证当前播放确实经过代理（此步尚未注入）", flush=True)
        existing = current_status()
        if existing and existing.get("active_arm_id"):
            raise RuntimeError("代理控制权已由 %s 持有" % existing["active_arm_id"])
        atomic_write_json(CONTROL, {"mode": "none"})
        route_offset = os.path.getsize(LOG) if os.path.exists(LOG) else 0
        send_j(mpv_pid)
        route_row = wait_for(
            lambda: next((row for row in parse_log_from(route_offset)
                         if is_media_get(row) and row.get("mode") == "none" and
                         row.get("injected") is not True), None),
            args.route_timeout,
        )
        if not route_row:
            raise RuntimeError("代理链路未接通：J 后未出现新的媒体 GET；本轮禁止判定")
        result["route_verified"] = True
        result["route_request"] = route_row

        print("[2/4] 原子写入并回读唯一 arm ID", flush=True)
        command = {"action": "arm", "arm_id": arm_id, "mode": args.mode}
        atomic_write_json(CONTROL, command)
        if read_json(CONTROL) != command:
            raise RuntimeError("控制文件回读不一致")
        armed = wait_for(
            lambda: (status if (status := current_status()) and
                    status.get("state") == "armed" and
                    status.get("active_arm_id") == arm_id and
                    status.get("active_mode") == args.mode else None),
            5,
        )
        if not armed:
            raise RuntimeError("代理未确认本轮 arm；可能仍在运行旧版代理或控制权被占用")

        print("[3/4] 连续 J；只以相同 arm ID 的代理命中为停止条件", flush=True)
        hit_deadline = time.time() + args.hit_timeout
        hit = None
        while time.time() < hit_deadline and not hit:
            send_j(mpv_pid)
            step_deadline = min(hit_deadline, time.time() + args.seek_interval)
            while time.time() < step_deadline:
                status = current_status()
                last_hit = status.get("last_hit") if status else None
                if last_hit and last_hit.get("arm_id") == arm_id:
                    hit = last_hit
                    break
                time.sleep(0.1)
        if not hit:
            raise RuntimeError("超时仍无相同 arm ID 的注入命中；本轮禁止判定")
        hit_row = wait_for(
            lambda: next((row for row in parse_log_from(log_offset)
                         if row.get("arm_id") == arm_id and row.get("injected") is True), None),
            5,
        )
        if not hit_row:
            raise RuntimeError("状态已命中但缺少同 arm ID 的 per-request 注入日志")
        result["injection_hit"] = True
        result["hit"] = hit
        result["hit_log"] = hit_row

        print("[4/4] 已停止 J，等待 %d 秒收敛并持续镜像证据" % args.settle, flush=True)
        time.sleep(args.settle)
    except Exception as error:
        result["error"] = "%s: %s" % (type(error).__name__, error)
        raise
    finally:
        atomic_write_json(CONTROL, {"action": "disarm", "arm_id": arm_id})
        time.sleep(0.2)
        atomic_write_json(CONTROL, {"mode": "none"})
        mirror.stop()
        snapshot_benchmark(evidence_dir, started_at)
        rows = parse_log_from(log_offset)
        with open(os.path.join(evidence_dir, "proxy-round.jsonl"), "w", encoding="utf-8") as stream:
            for row in rows:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
        outcomes, events = collect_outcomes(evidence_dir)
        result["journal_outcomes"] = outcomes
        result["events"] = events
        result["finished_at"] = time.time()
        atomic_write_json(os.path.join(evidence_dir, "round_result.json"), result)

    print("回合证据:", evidence_dir)
    print("journal outcomes:", result["journal_outcomes"])
    print("events:", result["events"])
    print("注意：脚本只证明链路与注入有效；最终通过仍需核对 end-file/position 且无 title-eof/completed。")


if __name__ == "__main__":
    main()
