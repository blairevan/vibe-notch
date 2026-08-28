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
    log(f"Notify bridge called with argv={sys.argv}")
    home = os.path.expanduser("~")
    sessions_dir = os.path.join(home, ".codex", "sessions")
    
    session_id = None
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
                "cwd": home
            }
            subprocess.run(["python3", hook_script], input=json.dumps(p1), text=True)
            
            time.sleep(0.3)
            
            p2 = {
                "hook_event_name": "Stop",
                "session_id": session_id,
                "cwd": home
            }
            subprocess.run(["python3", hook_script], input=json.dumps(p2), text=True)
            log("Successfully triggered Vibe Notch completion hook.")

    # Also forward to SkyComputerUseClient if installed
    sky_client = os.path.join(home, ".codex", "computer-use", "Codex Computer Use.app", "Contents", "SharedSupport", "SkyComputerUseClient.app", "Contents", "MacOS", "SkyComputerUseClient")
    if os.path.exists(sky_client):
        try:
            cmd = [sky_client] + (sys.argv[1:] if len(sys.argv) > 1 else ["turn-ended"])
            subprocess.run(cmd, check=False)
        except Exception:
            pass

if __name__ == "__main__":
    main()
