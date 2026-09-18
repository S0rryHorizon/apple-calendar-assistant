"""Exercise the notification smoke script with a temporary, synthetic bridge."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "notification-smoke-test.sh"
FAKE_BRIDGE = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

request = json.load(sys.stdin)
with Path(os.environ["FAKE_LOG"]).open("a", encoding="utf-8") as log:
    log.write(json.dumps(request, ensure_ascii=False) + "\n")

action = request["action"]
stage = ("setup" if action == "setup" else
         "cleanup" if action == "batch.rollback" else
         "preview" if request.get("dryRun") is True else "commit")
batch_id = request.get("batchId")
status = {"setup": "ok", "preview": "preview", "commit": "committed", "cleanup": "rolled_back"}[stage]
response = {"ok": True, "status": status}
if stage != "setup":
    response["batchId"] = batch_id
if stage == "preview":
    response.update(conflicts=[], duplicates=[])

if os.environ.get("FAKE_STAGE") == stage:
    mode = os.environ.get("FAKE_MODE", "")
    if mode == "exit":
        print(json.dumps(response))
        sys.exit(7)
    if mode == "invalid_json":
        print("{bad-json")
        sys.exit(0)
    if mode == "array":
        print("[]")
        sys.exit(0)
    if mode == "conflict":
        response["conflicts"] = [{"id": "existing-event"}]
    if mode == "duplicate":
        response["duplicates"] = [{"id": "existing-event"}]
    if mode in ("error", "unknown", "needs_confirmation"):
        response.update(ok=(mode == "needs_confirmation"), status=mode)
    if mode == "wrong_status":
        response["status"] = "preview" if stage != "preview" else "ok"
    if mode == "false_ok":
        response["ok"] = False
    if mode == "missing_id":
        response.pop("batchId", None)
    if mode == "wrong_id":
        response["batchId"] = "another-batch"
    if mode == "missing_lists":
        response.pop("conflicts", None)
        response.pop("duplicates", None)
print(json.dumps(response, ensure_ascii=False))
'''


class NotificationSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.bridge = self.base / "fake bridge with spaces"
        self.bridge.write_text(FAKE_BRIDGE, encoding="utf-8")
        self.bridge.chmod(0o755)
        self.script = self.base / "notification smoke script.sh"
        shutil.copy2(SCRIPT, self.script)
        self.log = self.base / "calls.jsonl"

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args, stage="", mode=""):
        env = os.environ.copy()
        env.update(CALENDAR_BRIDGE_PATH=str(self.bridge), FAKE_LOG=str(self.log),
                   FAKE_STAGE=stage, FAKE_MODE=mode)
        return subprocess.run(["/bin/zsh", str(self.script), *args], env=env,
                              text=True, capture_output=True, check=False)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_success_uses_one_canonical_item_and_matching_batch_id(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        setup, preview, commit = self.calls()
        self.assertEqual(setup, {"action": "setup"})
        self.assertEqual(preview["action"], "event.create")
        self.assertIs(preview["dryRun"], True)
        self.assertNotIn("confirmed", preview)
        self.assertTrue(preview["batchId"].startswith("notification-smoke-"))
        expected = dict(preview)
        expected.pop("dryRun")
        expected["confirmed"] = True
        self.assertEqual(commit, expected)
        self.assertIn("请等待约一分钟", result.stdout)
        self.assertIn(preview["batchId"], result.stdout)
        cleanup_command = result.stdout.splitlines()[-1].strip()
        cleanup_env = os.environ.copy()
        cleanup_env.pop("CALENDAR_BRIDGE_PATH", None)
        cleanup_env["FAKE_LOG"] = str(self.log)
        cleanup = subprocess.run(["/bin/zsh", "-c", cleanup_command], env=cleanup_env,
                                 text=True, capture_output=True, check=False)
        self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
        self.assertEqual(self.calls()[-1], {"action": "batch.rollback",
                                            "batchId": preview["batchId"], "confirmed": True})

    def test_preview_conflict_or_duplicate_stops_before_commit(self):
        for mode in ("conflict", "duplicate"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self.run_script(stage="preview", mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([c["action"] for c in self.calls()], ["setup", "event.create"])
                self.assertNotIn("请等待约一分钟", result.stdout)
                self.assertIn(self.calls()[-1]["batchId"], result.stderr)

    def test_each_stage_rejects_uncertain_or_invalid_receipts(self):
        for stage in ("setup", "preview", "commit", "cleanup"):
            for mode in ("error", "unknown", "needs_confirmation", "invalid_json",
                         "array", "exit", "wrong_status", "false_ok"):
                with self.subTest(stage=stage, mode=mode):
                    self.log.unlink(missing_ok=True)
                    args = ("--cleanup", "cleanup-id") if stage == "cleanup" else ()
                    result = self.run_script(*args, stage=stage, mode=mode)
                    self.assertNotEqual(result.returncode, 0)
                    expected_count = {"setup": 1, "preview": 2, "commit": 3, "cleanup": 1}[stage]
                    self.assertEqual(len(self.calls()), expected_count)
                    self.assertNotIn("请等待约一分钟", result.stdout)
                    if stage != "setup":
                        self.assertIn(self.calls()[-1]["batchId"], result.stderr)

    def test_missing_or_mismatched_batch_id_and_missing_preview_lists_fail(self):
        for stage, mode in (("preview", "missing_id"), ("preview", "wrong_id"),
                            ("preview", "missing_lists"), ("commit", "missing_id"),
                            ("commit", "wrong_id"), ("cleanup", "missing_id"),
                            ("cleanup", "wrong_id")):
            with self.subTest(stage=stage, mode=mode):
                self.log.unlink(missing_ok=True)
                args = ("--cleanup", "cleanup-id") if stage == "cleanup" else ()
                result = self.run_script(*args, stage=stage, mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("请等待约一分钟", result.stdout)

    def test_cleanup_json_encodes_special_batch_id(self):
        batch_id = 'id"\\\n雪'
        result = self.run_script("--cleanup", batch_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [{"action": "batch.rollback", "batchId": batch_id,
                                         "confirmed": True}])
        self.assertIn("批次已回滚", result.stdout)

    def test_cleanup_requires_id_and_does_not_call_bridge(self):
        result = self.run_script("--cleanup")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
