import json
import os
import tempfile
import unittest
from unittest import mock

from acceptance_control import FaultControl, atomic_write_json, read_json


class FaultControlTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.control_path = os.path.join(self.temp.name, "control.json")
        self.status_path = os.path.join(self.temp.name, "status.json")
        atomic_write_json(self.control_path, {"mode": "none"})
        self.control = FaultControl(self.control_path, self.status_path)

    def tearDown(self):
        self.temp.cleanup()

    def arm(self, arm_id="round-a", mode="midstream_cut"):
        atomic_write_json(self.control_path, {"action": "arm", "arm_id": arm_id, "mode": mode})
        self.control.refresh()

    def test_legacy_none_cannot_clear_owned_arm(self):
        self.arm()
        atomic_write_json(self.control_path, {"mode": "none"})
        snapshot = self.control.snapshot()
        self.assertEqual("round-a", snapshot["arm_id"])
        self.assertEqual("midstream_cut", snapshot["mode"])
        self.assertEqual("armed", read_json(self.status_path)["state"])

    def test_competing_arm_cannot_replace_owner(self):
        self.arm()
        atomic_write_json(
            self.control_path,
            {"action": "arm", "arm_id": "round-b", "mode": "remote_changed"},
        )
        snapshot = self.control.snapshot()
        self.assertEqual("round-a", snapshot["arm_id"])
        self.assertEqual("arm-owned-by:round-a", read_json(self.status_path)["last_error"])

    def test_arm_is_claimed_exactly_once(self):
        self.arm()
        snapshot = self.control.snapshot()
        request = {"method": "GET", "range": "bytes=1-2"}
        self.assertTrue(self.control.claim(snapshot, request))
        self.assertFalse(self.control.claim(snapshot, request))
        status = read_json(self.status_path)
        self.assertEqual("hit", status["state"])
        self.assertEqual("round-a", status["last_hit"]["arm_id"])

        # 控制文件中仍是旧 arm 命令时不得自动重新武装。
        self.assertIsNone(self.control.snapshot()["arm_id"])

    def test_startup_fault_stays_owned_until_disarm(self):
        self.arm(mode="force_416")
        snapshot = self.control.snapshot()
        self.assertTrue(self.control.claim(snapshot, {"method": "GET", "range": "bytes=0-0"}))
        self.assertEqual("round-a", self.control.snapshot()["arm_id"])
        self.assertEqual("armed", read_json(self.status_path)["state"])

    def test_malformed_control_keeps_active_arm(self):
        self.arm()
        with open(self.control_path, "w", encoding="utf-8") as stream:
            stream.write("{")
        snapshot = self.control.snapshot()
        self.assertEqual("round-a", snapshot["arm_id"])
        self.assertTrue(read_json(self.status_path)["last_error"].startswith("control-read:"))

    def test_only_owner_can_disarm(self):
        self.arm()
        atomic_write_json(self.control_path, {"action": "disarm", "arm_id": "round-b"})
        self.control.refresh()
        self.assertEqual("round-a", self.control.snapshot()["arm_id"])
        atomic_write_json(self.control_path, {"action": "disarm", "arm_id": "round-a"})
        self.control.refresh()
        self.assertIsNone(self.control.snapshot()["arm_id"])

    def test_atomic_replace_retries_windows_sharing_violation(self):
        target = os.path.join(self.temp.name, "retry.json")
        real_replace = os.replace
        attempts = []

        def flaky_replace(source, destination):
            attempts.append(destination)
            if len(attempts) < 3:
                raise PermissionError("sharing violation")
            return real_replace(source, destination)

        with mock.patch("acceptance_control.os.replace", side_effect=flaky_replace):
            atomic_write_json(target, {"ok": True})
        self.assertEqual(3, len(attempts))
        self.assertEqual({"ok": True}, read_json(target))


if __name__ == "__main__":
    unittest.main()
