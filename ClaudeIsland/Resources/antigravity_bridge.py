#!/usr/bin/env python3
"""Forward Antigravity lifecycle and approved notification context to Vibe Notch."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


SOURCES = {"antigravity", "antigravity-cli", "antigravity-ide"}
EVENTS = {"SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"}


def _normalize_question_prompt(payload):
    """Extract bounded ask_question items; return None for any other tool call."""
    tool_call = payload.get("toolCall")
    if not isinstance(tool_call, dict) or tool_call.get("name") != "ask_question":
        return None
    args = tool_call.get("args")
    if not isinstance(args, dict):
        return None
    raw_questions = args.get("questions")
    if isinstance(raw_questions, str):
        try:
            raw_questions = json.loads(raw_questions)
        except (ValueError, TypeError):
            return None
    if not isinstance(raw_questions, list):
        return None
    questions = []
    for item in raw_questions[:10]:
        if not isinstance(item, dict):
            continue
        title = item.get("question")
        if not isinstance(title, str) or not title.strip():
            continue
        raw_opts = item.get("options")
        options = []
        if isinstance(raw_opts, list):
            for opt in raw_opts[:8]:
                if isinstance(opt, str) and opt.strip():
                    options.append(opt.strip()[:500])
        multi = item.get("is_multi_select") is True or item.get("multiSelect") is True
        questions.append({
            "question": title.strip()[:1000],
            "options": options,
            "multiSelect": multi,
        })
    if not questions:
        return None
    raw_step = payload.get("stepIdx")
    step_idx = raw_step if type(raw_step) is int and raw_step >= 0 else 0
    return {"stepIdx": step_idx, "questions": questions}


def normalize_event(event_name, payload):
    """Translate lifecycle fields and the context needed for a current-turn notification."""
    if event_name not in EVENTS or not isinstance(payload, dict):
        return None
    conversation = payload.get("conversationId")
    if not isinstance(conversation, str) or not conversation or len(conversation) > 200:
        return None
    question_prompt = None
    if event_name == "PreToolUse":
        question_prompt = _normalize_question_prompt(payload)
        if question_prompt is None:
            return None
    source = "antigravity-unknown"
    for field in ("transcriptPath", "artifactDirectoryPath"):
        path = payload.get(field)
        if not isinstance(path, str):
            continue
        parts = Path(path).parts
        # Match a data-root component, never an arbitrary substring in a project name.
        for index, part in enumerate(parts[:-1]):
            if part in SOURCES and (parts[index + 1] == "brain" or (index > 0 and parts[index - 1] == ".gemini")):
                source = part
                break
        if source != "antigravity-unknown":
            break
    workspaces = payload.get("workspacePaths")
    cwd = next((p for p in workspaces if isinstance(p, str) and p.startswith("/")), "") if isinstance(workspaces, list) else ""
    metadata = {
        "conversationId": conversation,
        "hasError": bool(payload.get("error")),
        "isSubagent": payload.get("isSubagent") is True or bool(payload.get("parentConversationId")),
    }
    for key in ("executionNum", "invocationNum", "initialNumSteps"):
        value = payload.get(key)
        if type(value) is int and value >= 0:
            metadata[key] = value
    if type(payload.get("fullyIdle")) is bool:
        metadata["fullyIdle"] = payload["fullyIdle"]
    if event_name in {"PreInvocation", "PreToolUse", "Stop"}:
        for key in ("transcriptPath", "lastUserInput", "error"):
            value = payload.get(key)
            if isinstance(value, str):
                metadata[key] = value[:65536] if key != "transcriptPath" else value[:4096]
    if question_prompt is not None:
        metadata["questionPrompt"] = question_prompt
    reason = payload.get("terminationReason")
    if isinstance(reason, str):
        # Only accept enum-shaped text; arbitrary error prose stays with the host.
        if len(reason) <= 100 and all(c.isascii() and (c.isalnum() or c == "_") for c in reason):
            metadata["terminationReason"] = reason
    is_waiting = event_name in {"Stop", "PreToolUse"}
    return {
        "session_id": f"{source}:{conversation}",
        "cwd": cwd,
        "event": event_name,
        "status": "waiting_for_input" if is_waiting else "processing",
        "client": source,
        "antigravity": metadata,
    }


def attach_process(event):
    """Locate the long-lived host ancestor instead of storing the short-lived hook PID."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,tty=,comm="],
            capture_output=True, text=True, timeout=0.3, check=True,
        )
        tree = {}
        for line in result.stdout.splitlines():
            parts = line.split(None, 3)
            if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
                tree[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
        pid = os.getppid()
        host = None
        ancestry = []
        for _ in range(30):
            info = tree.get(pid)
            if info is None:
                break
            parent, tty, command = info
            ancestry.append(command)
            name = Path(command).name
            if host is None and name in {"agy", "language_server", "language_server_macos_arm", "language_server_macos_x64"}:
                host = (pid, tty)
            pid = parent
        if host is None:
            return
        event["pid"] = host[0]
        if host[1] not in {"??", "?", "-"}:
            event["tty"] = host[1]
        # Installed IDE builds can share the App's data root. A CLI running inside
        # an IDE terminal still keeps its explicit CLI identity.
        if event["client"] in {"antigravity", "antigravity-unknown"} and "tty" not in event:
            if any("/Antigravity IDE.app/" in command for command in ancestry):
                event["client"] = "antigravity-ide"
                event["session_id"] = "antigravity-ide:" + event["antigravity"]["conversationId"]
    except (OSError, subprocess.SubprocessError, ValueError):
        # Missing process metadata only limits click-to-focus; events still work.
        return


def main():
    """Send one bounded socket frame, always returning a neutral hook result."""
    parser = argparse.ArgumentParser()
    parser.add_argument("event", choices=sorted(EVENTS))
    parser.add_argument("--socket", default="/tmp/claude-island.sock")
    args = parser.parse_args()
    try:
        # Bound memory even if a host includes a large final model response.
        raw = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
        if len(raw) <= 4 * 1024 * 1024:
            event = normalize_event(args.event, json.loads(raw))
            if event is not None:
                attach_process(event)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(0.2)
                    client.connect(args.socket)
                    client.sendall(json.dumps(event).encode("utf-8") + b"\n")
    except (OSError, ValueError, TypeError, RecursionError):
        # Notifications must not change permissions or stop/continue behavior.
        pass
    finally:
        print("{}")


if __name__ == "__main__":
    main()
