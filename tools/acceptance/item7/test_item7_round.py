import json
import os
import shutil
import tempfile
import time
import unittest
from unittest import mock

import item7_round


class EvidenceMirrorTest(unittest.TestCase):
    def test_active_session_is_captured_before_source_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = os.path.join(temp, "iso_temp")
            evidence = os.path.join(temp, "evidence")
            old_session = os.path.join(root, "iso_old")
            active_session = os.path.join(root, "iso_active")
            os.makedirs(old_session)
            os.makedirs(active_session)
            with open(os.path.join(old_session, "iso-progress.jsonl"), "w", encoding="utf-8") as stream:
                stream.write('{"outcome":"completed"}\n')
            time.sleep(0.02)
            with open(os.path.join(active_session, "iso-progress.jsonl"), "w", encoding="utf-8") as stream:
                stream.write('{"outcome":"position"}\n')

            with mock.patch.object(item7_round, "ROOT", root):
                mirror = item7_round.EvidenceMirror(evidence)
                mirror.start()
                time.sleep(0.3)
                shutil.rmtree(active_session)
                mirror.stop()

            captured = os.path.join(evidence, "live", "iso_active", "iso-progress.jsonl")
            self.assertTrue(os.path.isfile(captured))
            with open(captured, encoding="utf-8") as stream:
                self.assertEqual("position", json.loads(stream.readline())["outcome"])
            self.assertFalse(os.path.exists(os.path.join(evidence, "live", "iso_old")))


if __name__ == "__main__":
    unittest.main()
