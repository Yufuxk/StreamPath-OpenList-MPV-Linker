import http.client
import json
import os
import time
import uuid
import urllib.parse

from acceptance_control import atomic_write_json, read_json


RUNTIME = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "sp_accept")
HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "local_config.json"), "r", encoding="utf-8") as config_stream:
    CONFIG = json.load(config_stream)
CONTROL = os.path.join(RUNTIME, "proxy_control.json")
STATUS = os.path.join(RUNTIME, "proxy_status.json")
LOG = os.path.join(RUNTIME, "proxy_log.jsonl")


def wait_for(predicate, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return None


def status():
    try:
        return read_json(STATUS)
    except (OSError, json.JSONDecodeError):
        return {}


def log_rows(offset=0):
    with open(LOG, "r", encoding="utf-8") as stream:
        stream.seek(offset)
        return [json.loads(line) for line in stream if line.strip()]


def media_path():
    segments = CONFIG["mediaPathSegments"]
    return "/dav/" + "/".join(urllib.parse.quote(value, safe="") for value in segments)


def ranged_get(path):
    connection = http.client.HTTPConnection("127.0.0.1", int(CONFIG["proxyPortA"]), timeout=40)
    connection.request("GET", path, headers={"Range": "bytes=8388608-8454143"})
    response = connection.getresponse()
    response_status = response.status
    try:
        response.read()
    except (http.client.IncompleteRead, ConnectionError, OSError):
        pass
    connection.close()
    return response_status


def main():
    path = media_path()
    arm_id = "proxy-selftest-%s" % uuid.uuid4().hex[:12]
    sticky_id = "proxy-sticky-selftest-%s" % uuid.uuid4().hex[:12]
    offset = os.path.getsize(LOG)
    try:
        atomic_write_json(CONTROL, {"action": "arm", "arm_id": arm_id, "mode": "remote_changed"})
        armed = wait_for(lambda: (value if (value := status()).get("state") == "armed" and
                                  value.get("active_arm_id") == arm_id else None))
        if not armed:
            raise RuntimeError("代理未确认 arm")

        # 模拟并行脚本把控制文件重置为 none；已持有的 arm 必须继续有效。
        atomic_write_json(CONTROL, {"mode": "none"})
        time.sleep(0.2)
        if status().get("active_arm_id") != arm_id:
            raise RuntimeError("普通 none 错误清除了已持有的 arm")

        first_status = ranged_get(path)
        hit = wait_for(lambda: (value if (value := status()).get("last_hit", {}).get("arm_id") == arm_id else None))
        if not hit:
            raise RuntimeError("请求未命中相同 arm ID")
        second_status = ranged_get(path)
        time.sleep(0.2)
        injected = [row for row in log_rows(offset)
                    if row.get("arm_id") == arm_id and row.get("injected") is True]
        if len(injected) != 1:
            raise RuntimeError("预期单次注入，实际 %d 次" % len(injected))
        if first_status != 200:
            raise RuntimeError("remote_changed 首次响应应为 200，实际 %d" % first_status)
        if second_status == 200:
            raise RuntimeError("第二次请求仍呈现 remote_changed 注入语义")

        atomic_write_json(CONTROL, {"action": "arm", "arm_id": sticky_id, "mode": "force_416"})
        sticky_armed = wait_for(lambda: (value if (value := status()).get("state") == "armed" and
                                         value.get("active_arm_id") == sticky_id else None))
        if not sticky_armed:
            raise RuntimeError("代理未确认启动探测 sticky arm")
        atomic_write_json(CONTROL, {"mode": "none"})
        time.sleep(0.2)
        sticky_first = ranged_get(path)
        sticky_second = ranged_get(path)
        sticky_injected = [row for row in log_rows(offset)
                           if row.get("arm_id") == sticky_id and row.get("injected") is True]
        if sticky_first != 416 or sticky_second != 416 or len(sticky_injected) != 2:
            raise RuntimeError("启动探测 arm 未保持到显式 disarm")
        atomic_write_json(CONTROL, {"action": "disarm", "arm_id": sticky_id})
        if not wait_for(lambda: status().get("active_arm_id") is None):
            raise RuntimeError("启动探测 arm 未解除")
        after_disarm_status = ranged_get(path)
        if after_disarm_status != 206:
            raise RuntimeError("disarm 后未恢复真实 206")
        print(json.dumps({
            "one_shot_arm_confirmed": True,
            "legacy_none_did_not_clear": True,
            "hit_confirmed": True,
            "one_shot_injection_count": len(injected),
            "one_shot_statuses": [first_status, second_status],
            "sticky_arm_confirmed": True,
            "sticky_injection_count": len(sticky_injected),
            "sticky_statuses": [sticky_first, sticky_second, after_disarm_status],
        }, ensure_ascii=False, indent=2))
    finally:
        atomic_write_json(CONTROL, {"action": "disarm", "arm_id": arm_id})
        time.sleep(0.1)
        atomic_write_json(CONTROL, {"action": "disarm", "arm_id": sticky_id})
        time.sleep(0.1)
        atomic_write_json(CONTROL, {"mode": "none"})


if __name__ == "__main__":
    main()
