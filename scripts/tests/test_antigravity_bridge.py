"""Exercise the bridge contract without a model call or user configuration writes."""

import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch


BRIDGE = Path(__file__).resolve().parents[2] / "ClaudeIsland/Resources/antigravity_bridge.py"


class AntigravityBridgeTests(unittest.TestCase):
    """Catch origin confusion, privacy leaks, and blocking hook behavior."""

    def load_bridge(self):
        """Load the production bridge after asserting that it exists."""
        self.assertTrue(BRIDGE.exists(), "Antigravity bridge is not implemented")
        spec = importlib.util.spec_from_file_location("antigravity_bridge", BRIDGE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def payload(self, source="antigravity-cli"):
        """Return a minimal upstream Stop event with intentionally private text."""
        return {
            "conversationId": "test-conversation",
            "workspacePaths": ["/workspace/demo"],
            "transcriptPath": f"/home/test/.gemini/{source}/brain/test-conversation/.system_generated/logs/transcript.jsonl",
            "lastUserInput": "PRIVATE_PROMPT",
            "finalModelOutput": "PRIVATE_REPLY",
            "executionNum": 2,
            "fullyIdle": True,
            "terminationReason": "NO_TOOL_CALL",
        }

    def test_all_three_origins_remain_distinct(self):
        """The transcript root determines identity without depending on the hook PID."""
        bridge = self.load_bridge()
        for source in ["antigravity", "antigravity-cli", "antigravity-ide"]:
            with self.subTest(source=source):
                event = bridge.normalize_event("Stop", self.payload(source))
                self.assertEqual(event["client"], source)
                self.assertEqual(event["session_id"], f"{source}:test-conversation")
                self.assertEqual(event["antigravity"]["terminationReason"], "NO_TOOL_CALL")

    def test_ide_shared_data_root_uses_host_ancestry(self):
        """The installed IDE uses the app data root but an IDE-owned agy hub process."""
        bridge = self.load_bridge()
        event = bridge.normalize_event("Stop", self.payload("antigravity"))
        snapshot = subprocess.CompletedProcess([], 0, stdout=(
            "300 200 ?? /bin/sh\n"
            "200 100 ?? /home/test/.gemini/bin/agy\n"
            "100 1 ?? /Applications/Antigravity IDE.app/Contents/MacOS/Electron\n"
        ))
        with patch.object(bridge.subprocess, "run", return_value=snapshot), patch.object(bridge.os, "getppid", return_value=300):
            bridge.attach_process(event)
        self.assertEqual(event["client"], "antigravity-ide")
        self.assertEqual(event["session_id"], "antigravity-ide:test-conversation")
        self.assertEqual(event["pid"], 200)

    def test_cli_inside_ide_is_still_cli(self):
        """A terminal hosting agy does not change the CLI's product identity."""
        bridge = self.load_bridge()
        event = bridge.normalize_event("Stop", self.payload("antigravity-cli"))
        snapshot = subprocess.CompletedProcess([], 0, stdout=(
            "300 200 ttys001 /bin/sh\n"
            "200 100 ttys001 /home/test/.local/bin/agy\n"
            "100 1 ?? /Applications/Antigravity IDE.app/Contents/MacOS/Electron\n"
        ))
        with patch.object(bridge.subprocess, "run", return_value=snapshot), patch.object(bridge.os, "getppid", return_value=300):
            bridge.attach_process(event)
        self.assertEqual(event["client"], "antigravity-cli")
        self.assertEqual(event["tty"], "ttys001")

    def test_bridge_only_forwards_approved_notification_fields(self):
        """Prompt, error, and log location support rich notifications; raw reply stays local."""
        bridge = self.load_bridge()
        payload = self.payload()
        payload["error"] = "PRIVATE_ERROR"
        event = bridge.normalize_event("Stop", payload)
        self.assertEqual(event["antigravity"].get("lastUserInput"), "PRIVATE_PROMPT")
        self.assertEqual(event["antigravity"].get("error"), "PRIVATE_ERROR")
        self.assertEqual(event["antigravity"].get("transcriptPath"), payload["transcriptPath"])
        self.assertNotIn("PRIVATE_REPLY", json.dumps(event))
        self.assertTrue(event["antigravity"]["hasError"])

    def test_missing_identity_is_ignored_and_unknown_origin_is_explicit(self):
        """Incomplete payloads cannot merge unrelated conversations."""
        bridge = self.load_bridge()
        self.assertIsNone(bridge.normalize_event("Stop", {}))
        event = bridge.normalize_event("Stop", {"conversationId": "one"})
        self.assertEqual(event["client"], "antigravity-unknown")

    def test_legacy_data_root_without_brain_is_recognized(self):
        """Older host payloads place the transcript directly under the product root."""
        bridge = self.load_bridge()
        payload = self.payload()
        payload["transcriptPath"] = "/home/test/.gemini/antigravity-ide/transcript.jsonl"
        self.assertEqual(bridge.normalize_event("Stop", payload)["client"], "antigravity-ide")

    def test_background_stop_and_subagent_metadata_survive(self):
        """The app must be able to suppress premature or nested completions."""
        bridge = self.load_bridge()
        payload = self.payload()
        payload.update(fullyIdle=False, parentConversationId="parent")
        event = bridge.normalize_event("Stop", payload)
        self.assertFalse(event["antigravity"]["fullyIdle"])
        self.assertTrue(event["antigravity"]["isSubagent"])

    def test_real_socket_delivery_and_neutral_stdout(self):
        """The executable sends one frame and never changes host stop decisions."""
        self.load_bridge()
        with tempfile.TemporaryDirectory(prefix="agy-test-") as directory:
            path = str(Path(directory) / "events.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(2)
                result = subprocess.run(
                    ["python3", str(BRIDGE), "Stop", "--socket", path],
                    input=json.dumps(self.payload()), text=True,
                    capture_output=True, timeout=3,
                )
                with server.accept()[0] as client:
                    data = client.recv(65536)
                self.assertEqual(json.loads(data)["client"], "antigravity-cli")
                self.assertEqual(json.loads(result.stdout), {})
                self.assertEqual(result.returncode, 0)

    def test_unavailable_socket_and_malformed_input_fail_open(self):
        """Notification infrastructure cannot prevent the agent from continuing."""
        self.load_bridge()
        for payload in ["invalid", json.dumps(self.payload()), "[]"]:
            result = subprocess.run(
                ["python3", str(BRIDGE), "Stop", "--socket", "/nonexistent/vibe-test.sock"],
                input=payload, text=True, capture_output=True, timeout=3,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})

    def test_pre_tool_use_ask_question_array_and_json_string(self):
        """ask_question PreToolUse emits waiting_for_input and normalizes array or JSON-string questions."""
        bridge = self.load_bridge()
        raw_questions = [
            {
                "question": "统一采用哪种来源命名？",
                "options": ["(Recommended) 英文", "中文", "   "],
                "is_multi_select": False,
            },
            {
                "question": "需要同步哪些端？",
                "options": ["Web", "Telegram", "DingTalk"],
                "is_multi_select": True,
            },
        ]
        for encoded in (raw_questions, json.dumps(raw_questions, ensure_ascii=False)):
            with self.subTest(kind=type(encoded).__name__):
                payload = {
                    "conversationId": "ask-conv",
                    "stepIdx": 42,
                    "workspacePaths": ["/workspace/toolhub"],
                    "transcriptPath": "/home/test/.gemini/antigravity/brain/ask-conv/.system_generated/logs/transcript.jsonl",
                    "lastUserInput": "<USER_REQUEST>对齐命名规范</USER_REQUEST>",
                    "toolCall": {
                        "name": "ask_question",
                        "args": {"questions": encoded},
                    },
                }
                event = bridge.normalize_event("PreToolUse", payload)
                self.assertIsNotNone(event)
                self.assertEqual(event["status"], "waiting_for_input")
                self.assertEqual(event["client"], "antigravity")
                self.assertEqual(event["antigravity"]["lastUserInput"], payload["lastUserInput"])
                self.assertEqual(event["antigravity"]["transcriptPath"], payload["transcriptPath"])
                prompt = event["antigravity"]["questionPrompt"]
                self.assertEqual(prompt["stepIdx"], 42)
                self.assertEqual(len(prompt["questions"]), 2)
                self.assertEqual(prompt["questions"][0]["question"], "统一采用哪种来源命名？")
                self.assertEqual(prompt["questions"][0]["options"], ["(Recommended) 英文", "中文"])
                self.assertFalse(prompt["questions"][0]["multiSelect"])
                self.assertTrue(prompt["questions"][1]["multiSelect"])

    def test_pre_tool_use_non_ask_question_is_ignored_and_cli_prints_empty_json(self):
        """Unrelated PreToolUse payloads never emit socket frames and still output neutral JSON."""
        bridge = self.load_bridge()
        payload = {
            "conversationId": "ask-conv",
            "stepIdx": 7,
            "toolCall": {"name": "read_file", "args": {"Path": "/tmp/demo"}},
        }
        self.assertIsNone(bridge.normalize_event("PreToolUse", payload))
        result = subprocess.run(
            ["python3", str(BRIDGE), "PreToolUse", "--socket", "/nonexistent/vibe-test.sock"],
            input=json.dumps(payload), text=True, capture_output=True, timeout=3,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})


if __name__ == "__main__":
    unittest.main()
