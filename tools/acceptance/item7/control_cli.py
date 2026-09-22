import argparse
import json
import os
import time

from acceptance_control import OWNED_MODES, atomic_write_json, read_json


RUNTIME = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "sp_accept")
CONTROL = os.path.join(RUNTIME, "proxy_control.json")
STATUS = os.path.join(RUNTIME, "proxy_status.json")


def wait_for(predicate, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            value = read_json(STATUS)
        except (OSError, json.JSONDecodeError):
            value = None
        if value and predicate(value):
            return value
        time.sleep(0.05)
    raise RuntimeError("代理未在时限内确认控制命令")


def main():
    parser = argparse.ArgumentParser(description="第 7 条验收代理控制")
    subparsers = parser.add_subparsers(dest="action", required=True)
    arm = subparsers.add_parser("arm")
    arm.add_argument("mode", choices=sorted(OWNED_MODES))
    arm.add_argument("arm_id")
    disarm = subparsers.add_parser("disarm")
    disarm.add_argument("arm_id")
    subparsers.add_parser("none")
    args = parser.parse_args()

    os.makedirs(RUNTIME, exist_ok=True)
    if args.action == "arm":
        command = {"action": "arm", "mode": args.mode, "arm_id": args.arm_id}
        atomic_write_json(CONTROL, command)
        if read_json(CONTROL) != command:
            raise RuntimeError("控制文件回读不一致")
        value = wait_for(lambda item: item.get("state") == "armed" and
                         item.get("active_arm_id") == args.arm_id and
                         item.get("active_mode") == args.mode)
    elif args.action == "disarm":
        atomic_write_json(CONTROL, {"action": "disarm", "arm_id": args.arm_id})
        value = wait_for(lambda item: item.get("active_arm_id") != args.arm_id)
        atomic_write_json(CONTROL, {"mode": "none"})
    else:
        value = read_json(STATUS)
        if value.get("active_arm_id"):
            raise RuntimeError("代理控制权由 %s 持有，拒绝普通 none" % value["active_arm_id"])
        atomic_write_json(CONTROL, {"mode": "none"})
        value = wait_for(lambda item: item.get("active_arm_id") is None and
                         item.get("legacy_mode") == "none")
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    main()
