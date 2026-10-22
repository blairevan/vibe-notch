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

def is_codex_turn_completed(session_id, home):
    sessions_dir = os.path.join(home, ".codex", "sessions")
    if not os.path.exists(sessions_dir):
        return True
    files = glob.glob(os.path.join(sessions_dir, "**", f"*{session_id}*.jsonl"), recursive=True)
    if not files:
        return True
    target_file = max(files, key=os.path.getmtime)
    try:
        with open(target_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in reversed(f.readlines()):
                if '"task_complete"' in line or '"task_started"' in line:
                    try:
                        d = json.loads(line)
                        if d.get("type") == "event_msg":
                            pt = d.get("payload", {}).get("type")
                            if pt == "task_complete":
                                return True
                            elif pt == "task_started":
                                return False
                    except Exception:
                        pass
    except Exception as e:
        log(f"Error checking turn completion: {e}")
    return True

def is_codex_subagent(session_id, home):
    sessions_dir = os.path.join(home, ".codex", "sessions")
    if not os.path.exists(sessions_dir):
        return False
    files = glob.glob(os.path.join(sessions_dir, "**", f"*{session_id}*.jsonl"), recursive=True)
    if not files:
        return False
    target_file = max(files, key=os.path.getmtime)
    try:
        with open(target_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if '"session_meta"' in line:
                    try:
                        d = json.loads(line)
                        if d.get("type") == "session_meta":
                            payload = d.get("payload", {})
                            if payload.get("thread_source") == "subagent" or payload.get("parent_thread_id"):
                                return True
                            source = payload.get("source")
                            if isinstance(source, dict) and "subagent" in source:
                                return True
                            return False
                    except Exception:
                        pass
    except Exception as e:
        log(f"Error checking subagent: {e}")
    return False

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
                    
                    if (data.get("thread-source") == "subagent" or
                        data.get("thread_source") == "subagent" or
                        data.get("parent-thread-id") or
                        data.get("parent_thread_id")):
                        log("Ignoring subagent turn from notify payload.")
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
                sorted_files = sorted(files, key=os.path.getmtime, reverse=True)
                for candidate_file in sorted_files[:10]:
                    try:
                        with open(candidate_file, "r", encoding="utf-8", errors="ignore") as f:
                            first_line = f.readline()
                            if '"session_meta"' in first_line:
                                data = json.loads(first_line)
                                if data.get("type") == "session_meta":
                                    payload = data.get("payload", {})
                                    if payload.get("thread_source") == "subagent" or payload.get("parent_thread_id"):
                                        continue
                                    source = payload.get("source")
                                    if isinstance(source, dict) and "subagent" in source:
                                        continue
                                    session_id = payload.get("session_id") or payload.get("id")
                                    break
                    except Exception as e:
                        log(f"Error reading session file {candidate_file}: {e}")

    if session_id:
        if is_codex_subagent(session_id, home):
            log(f"Session {session_id} is a subagent turn, ignoring.")
            return

        if not is_codex_turn_completed(session_id, home):
            log(f"Session {session_id} turn still in progress (latest event is not task_complete), ignoring turn-ended notify.")
            return

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
