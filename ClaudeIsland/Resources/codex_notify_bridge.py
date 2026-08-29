#!/usr/bin/env python3
"""
Codex Native Notify Bridge for Vibe Notch
Automatically executed by Codex Desktop upon turn completion via notify configuration in ~/.codex/config.toml.
"""
import glob
import json
import os
import subprocess
import sys
import time

LOG_PATH = "/tmp/vibe-notch-flow.log"

def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{os.getpid()}] [codex-notify-bridge] {msg}\n")
    except Exception:
        pass

def main():
    home = os.path.expanduser("~")
    session_id = None
    cwd = home

    # 1. Parse payload from Codex Desktop if passed in sys.argv
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            try:
                data = json.loads(arg)
                if isinstance(data, dict):
                    # Filter out internal title-generation background turns
                    input_msgs = data.get("input-messages") or []
                    for msg in input_msgs:
                        if isinstance(msg, str) and "provide a short title for a task" in msg:
                            log("Ignoring internal background title-generation turn.")
                            return
                    
                    session_id = data.get("thread-id") or data.get("thread_id") or data.get("session-id")
                    cwd = data.get("cwd") or home
                    break
            except Exception:
                continue

    # 2. Fallback: find latest rollout file
    if not session_id:
        sessions_dir = os.path.join(home, ".codex", "sessions")
        if os.path.exists(sessions_dir):
            files = glob.glob(os.path.join(sessions_dir, "**", "rollout-*.jsonl"), recursive=True)
            if files:
                latest_file = max(files, key=os.path.getmtime)
                try:
                    with open(latest_file, "r") as f:
                        for line in f:
                            data = json.loads(line)
                            if data.get("type") == "session_meta":
                                session_id = data.get("payload", {}).get("session_id")
                                break
                except Exception as e:
                    log(f"Error reading session file: {e}")

    if session_id:
        log(f"Resolved active Codex session: {session_id}")
        hook_script = os.path.join(home, ".codex", "hooks", "claude-island-state.py")
        if not os.path.exists(hook_script):
            hook_script = os.path.join(home, ".claude", "hooks", "claude-island-state.py")

        if os.path.exists(hook_script):
            p1 = {
                "hook_event_name": "UserPromptSubmit",
                "session_id": session_id,
                "cwd": cwd
            }
            subprocess.run(["python3", hook_script], input=json.dumps(p1), text=True)
            
            time.sleep(0.1)
            
            p2 = {
                "hook_event_name": "Stop",
                "session_id": session_id,
                "cwd": cwd
            }
            subprocess.run(["python3", hook_script], input=json.dumps(p2), text=True)
            log("Successfully forwarded Codex turn completion to Vibe Notch.")

if __name__ == "__main__":
    main()
