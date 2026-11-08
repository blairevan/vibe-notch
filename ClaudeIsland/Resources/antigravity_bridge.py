#!/usr/bin/env python3
"""Forward metadata-only Antigravity lifecycle events to Vibe Notch."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


SOURCES = {"antigravity", "antigravity-cli", "antigravity-ide"}
EVENTS = {"SessionStart", "PreInvocation", "PostToolUse", "Stop"}


def normalize_event(event_name, payload):
    """Translate upstream metadata without forwarding prompts, results, or errors."""
    if event_name not in EVENTS or not isinstance(payload, dict):
        return None
    conversation = payload.get("conversationId")
    if not isinstance(conversation, str) or not conversation or len(conversation) > 200:
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
    for key in ("executionNum", "invocationNum"):
        value = payload.get(key)
        if type(value) is int and value >= 0:
            metadata[key] = value
    if type(payload.get("fullyIdle")) is bool:
        metadata["fullyIdle"] = payload["fullyIdle"]
    reason = payload.get("terminationReason")
    if isinstance(reason, str):
        # Only accept enum-shaped text; arbitrary error prose stays with the host.
        if len(reason) <= 100 and all(c.isascii() and (c.isalnum() or c == "_") for c in reason):
            metadata["terminationReason"] = reason
    return {
        "session_id": f"{source}:{conversation}",
        "cwd": cwd,
        "event": event_name,
        "status": "processing" if event_name != "Stop" else "waiting_for_input",
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
