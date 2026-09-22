"""第 7 条故障注入控制状态机。"""

import json
import os
import threading
import time


ONE_SHOT_MODES = {"midstream_cut", "midstream_cut_body", "remote_changed"}
STICKY_MODES = {
    "redirect", "final_403", "force_416", "no_range", "no_validator",
    "bad_content_range",
}
OWNED_MODES = ONE_SHOT_MODES | STICKY_MODES


def atomic_write_json(path, value):
    temp_path = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
    with open(temp_path, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    for attempt in range(20):
        try:
            os.replace(temp_path, path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.01)


def read_json(path):
    with open(path, "r", encoding="utf-8") as stream:
        return json.load(stream)


class FaultControl:
    """Keeps an armed playback fault owned until exactly one request claims it."""

    def __init__(self, control_path, status_path):
        self.control_path = control_path
        self.status_path = status_path
        self._lock = threading.Lock()
        self._legacy_mode = "none"
        self._active = None
        self._seen_arm_ids = set()
        self._last_hit = None
        self._last_error = None
        self._last_control_signature = None
        self._publish_locked("idle")

    def _status_locked(self, state):
        return {
            "state": state,
            "active_arm_id": self._active["arm_id"] if self._active else None,
            "active_mode": self._active["mode"] if self._active else None,
            "legacy_mode": self._legacy_mode,
            "last_hit": self._last_hit,
            "last_error": self._last_error,
            "pid": os.getpid(),
            "updated_at": round(time.time(), 4),
        }

    def _publish_locked(self, state):
        atomic_write_json(self.status_path, self._status_locked(state))

    def refresh(self):
        try:
            metadata = os.stat(self.control_path)
            signature = (metadata.st_mtime_ns, metadata.st_size)
            with self._lock:
                if signature == self._last_control_signature:
                    return
            command = read_json(self.control_path)
        except Exception as error:
            with self._lock:
                try:
                    self._last_control_signature = signature
                except UnboundLocalError:
                    pass
                self._last_error = "control-read:%s" % type(error).__name__
                self._publish_locked("armed" if self._active else "idle")
            return

        action = command.get("action")
        with self._lock:
            self._last_control_signature = signature
            self._last_error = None
            if action == "arm":
                arm_id = str(command.get("arm_id", "")).strip()
                mode = command.get("mode")
                if not arm_id or mode not in OWNED_MODES:
                    self._last_error = "invalid-arm-command"
                elif arm_id in self._seen_arm_ids:
                    pass
                elif self._active is None:
                    self._active = {"arm_id": arm_id, "mode": mode}
                elif self._active != {"arm_id": arm_id, "mode": mode}:
                    self._last_error = "arm-owned-by:%s" % self._active["arm_id"]
            elif action == "disarm":
                arm_id = str(command.get("arm_id", "")).strip()
                if self._active and self._active["arm_id"] == arm_id:
                    self._seen_arm_ids.add(arm_id)
                    self._active = None
                elif self._active:
                    self._last_error = "disarm-owner-mismatch"
            elif self._active is None:
                self._legacy_mode = command.get("mode", "none")
            self._publish_locked("armed" if self._active else ("hit" if self._last_hit else "idle"))

    def snapshot(self):
        self.refresh()
        with self._lock:
            if self._active:
                return {"mode": self._active["mode"], "arm_id": self._active["arm_id"]}
            return {"mode": self._legacy_mode, "arm_id": None}

    def claim(self, snapshot, request):
        arm_id = snapshot.get("arm_id")
        if arm_id is None:
            return True
        with self._lock:
            if self._active != {"arm_id": arm_id, "mode": snapshot.get("mode")}:
                return False
            self._last_hit = {
                "arm_id": arm_id,
                "mode": snapshot["mode"],
                "request": request,
                "hit_at": round(time.time(), 4),
            }
            if snapshot["mode"] in ONE_SHOT_MODES:
                self._active = None
                self._seen_arm_ids.add(arm_id)
                self._publish_locked("hit")
            else:
                self._publish_locked("armed")
            return True

    def watch(self, interval=0.05):
        while True:
            self.refresh()
            time.sleep(interval)
