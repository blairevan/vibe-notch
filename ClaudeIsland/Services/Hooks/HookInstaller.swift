//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        updateSettings(at: ClaudePaths.settingsFile)
        installDshPluginIfNeeded()
        installCodexHooksIfNeeded()
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(ClaudePaths.hookScriptShellPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Strip any existing Claude Island hooks from ALL event types first — even
        // events we no longer register. Fixes users who installed v1.3 on an older
        // Claude Code and now have invalid keys like PermissionDenied sitting in
        // their settings.json (issue #85).
        var cleanedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let cleaned = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }
        hooks = cleanedHooks

        // Register only hooks the installed Claude Code version supports.
        // When detection fails, fall back to the baseline set that every
        // Claude Code version has supported (no new v1.3+ hooks).
        let installedVersion = detectClaudeCodeVersion()
        let hookEvents = supportedHookEvents(
            for: installedVersion,
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )

        for (event, config) in hookEvents {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
    }

    // MARK: - Claude Code Version Detection

    /// Simple semantic version used to gate which hook events we register.
    /// Claude Code rejects unknown hook keys, so we must only register
    /// events the installed version knows about.
    struct ClaudeCodeVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Runs `claude --version` and parses the result. Returns nil on any
    /// failure (binary not found, non-zero exit, unparseable output).
    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        // Claude Code can land in a few typical spots; try each until we find one
        let fm = FileManager.default
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseClaudeCodeVersion(from: output)
        } catch {
            return nil
        }
    }

    /// Extracts the first `X.Y.Z` token from arbitrary version output.
    /// Accepts any prefix/suffix — works for "2.1.88", "v2.1.88", "claude 2.1.88 (...)" etc.
    static func parseClaudeCodeVersion(from text: String) -> ClaudeCodeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange])
        else { return nil }
        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }

    /// Returns the ordered list of (event, config) pairs to register, filtered
    /// to only events the installed Claude Code version knows about.
    private static func supportedHookEvents(
        for version: ClaudeCodeVersion?,
        withMatcher: [[String: Any]],
        withMatcherAndTimeout: [[String: Any]],
        withoutMatcher: [[String: Any]],
        preCompactConfig: [[String: Any]]
    ) -> [(String, [[String: Any]])] {
        // Baseline — present in every Claude Code version that supports hooks
        var events: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        // Without a detected version, stick to the baseline — better to miss
        // features than to break settings.json on older Claude Code (#85).
        guard let version else { return events }

        // v2.0.x — PostToolUseFailure shipped alongside the PostToolUse redesign
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 0) {
            events.append(("PostToolUseFailure", withMatcher))
        }
        // v2.0.43 — SubagentStart, pairs with SubagentStop
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 43) {
            events.append(("SubagentStart", withoutMatcher))
        }
        // v2.1.76 — PostCompact, pairs with PreCompact
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 76) {
            events.append(("PostCompact", preCompactConfig))
        }
        // v2.1.78 — StopFailure on API errors (rate limit, auth, billing)
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 78) {
            events.append(("StopFailure", withoutMatcher))
        }
        // v2.1.88 — PermissionDenied for auto-mode classifier denials
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 88) {
            events.append(("PermissionDenied", withMatcher))
        }

        return events
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let settings = ClaudePaths.settingsFile

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = ClaudePaths.settingsFile

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries = entries.compactMap { removingClaudeIslandHooks(from: $0) }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    nonisolated private static func removingClaudeIslandHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isClaudeIslandHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isClaudeIslandHook(_ hook: [String: Any]) -> Bool {
        let cmd = hook["command"] as? String ?? ""
        return cmd.contains("claude-island-state.py")
    }
    /// Installs DSH (DeepSeek Harness) notification plugin into ~/.dsh/plugins/dsh-vibe-notch and registers it in profile
    static func installDshPluginIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dshDir = home + "/.dsh"
        guard fm.fileExists(atPath: dshDir) else { return }

        let pluginDir = dshDir + "/plugins/dsh-vibe-notch"
        let libDir = pluginDir + "/lib"
        try? fm.createDirectory(atPath: libDir, withIntermediateDirectories: true)

        let pkgJsonPath = pluginDir + "/package.json"
        let cordisPatchPath = pluginDir + "/cordis.patch.yml"
        let indexPath = libDir + "/index.js"

        let pkgJsonContent = """
{
  "name": "dsh-vibe-notch",
  "description": "Vibe Notch integration plugin for DeepSeek Harness",
  "version": "1.0.0",
  "type": "module",
  "main": "lib/index.js",
  "license": "MIT",
  "dsh": {
    "bundle": {
      "patch": "./cordis.patch.yml"
    }
  }
}
"""

        let cordisPatchContent = """
- insert:
    - id: vibe-notch
      name: 'dsh-vibe-notch'
"""

        let indexJsContent = """
import net from 'node:net';
import fs from 'node:fs';

const SOCKET_PATH = '/tmp/claude-island.sock';
const LOG_PATH = '/tmp/vibe-notch-flow.log';

function log(msg) {
  try {
    fs.appendFileSync(LOG_PATH, '[' + process.pid + '] [dsh-plugin] ' + msg + '\\n');
  } catch {}
}

const isDesktop = process.execPath.includes('DeepSeek Harness Desktop') ||
                  process.argv.some(arg => typeof arg === 'string' && arg.includes('DeepSeek Harness Desktop')) ||
                  Boolean(process.env.DSH_DESKTOP);

const dshClientType = isDesktop ? 'dsh-desktop' : 'dsh-web';

log('dsh-vibe-notch plugin loaded, clientType=' + dshClientType);

function sendEvent(payload) {
  const fullPayload = {
    ...payload,
    client: dshClientType
  };
  log('sendEvent connecting: event=' + fullPayload.event + ', status=' + fullPayload.status + ', client=' + fullPayload.client + ', tool=' + (fullPayload.tool || 'none'));
  try {
    const client = net.createConnection(SOCKET_PATH, () => {
      client.write(JSON.stringify(fullPayload), () => {
        client.end();
        log('sendEvent success for ' + fullPayload.event);
      });
    });
    client.on('error', (err) => {
      log('sendEvent socket error: ' + err.message);
    });
  } catch (err) {
    log('sendEvent exception: ' + err.message);
  }
}

// Track pending/recent tool calls by sessionId
const activeToolCalls = new Map();

function parseToolArguments(raw) {
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch {}
    return { command: raw };
  }
  return {};
}

export function apply(ctx) {
  log('dsh-vibe-notch apply(ctx) registered, clientType=' + dshClientType);

  ctx.on('session/created', (session) => {
    log('session/created: ' + (session.id || '').slice(0, 8));
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionStart',
      status: 'waiting_for_input',
      pid: process.pid
    });
  }, { global: true });

  ctx.on('session/event', (session, event) => {
    const cwd = session.header?.cwd || process.cwd();
    const sessionId = session.id;
    log('session/event: type=' + event.type + ', sid=' + (sessionId || '').slice(0, 8));

    if (event.type === 'turn/start') {
      activeToolCalls.delete(sessionId);
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'UserPromptSubmit',
        status: 'processing',
        pid: process.pid
      });
    } else if (event.type === 'tool/call') {
      const toolName = event.data?.name || event.data?.tool || 'unknown';
      const callId = event.data?.callId || ('call-' + Date.now());
      const toolInput = parseToolArguments(event.data?.arguments || event.data?.input);

      activeToolCalls.set(sessionId, {
        toolName,
        callId,
        toolInput
      });

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PreToolUse',
        status: 'running_tool',
        tool: toolName,
        tool_name: toolName,
        tool_use_id: callId,
        tool_input: toolInput,
        pid: process.pid
      });
    } else if (event.type === 'tool/result') {
      const callId = event.data?.callId || activeToolCalls.get(sessionId)?.callId;
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PostToolUse',
        status: 'processing',
        tool_use_id: callId,
        pid: process.pid
      });
    } else if (event.type === 'approval/asked') {
      const lastCall = activeToolCalls.get(sessionId);
      const toolName = event.data?.toolName || lastCall?.toolName || 'tool';
      const approvalId = event.data?.id || event.data?.callId || lastCall?.callId || ('approval-' + Date.now());
      const reason = event.data?.reason || '';
      
      const combinedInput = {
        ...(lastCall?.toolInput || {}),
        ...(reason ? { reason } : {})
      };

      log('approval/asked: tool=' + toolName + ', reason=' + reason + ', id=' + approvalId);

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PermissionRequest',
        status: 'waiting_for_approval',
        tool: toolName,
        tool_name: toolName,
        tool_use_id: approvalId,
        tool_input: combinedInput,
        reason: reason,
        message: reason,
        pid: process.pid
      });
    } else if (event.type === 'approval/decided') {
      const approvalId = event.data?.id;
      const outcome = event.data?.outcome;
      log('approval/decided: outcome=' + outcome + ', id=' + approvalId);

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PostToolUse',
        status: 'processing',
        tool_use_id: approvalId,
        pid: process.pid
      });
    } else if (event.type === 'turn/end') {
      activeToolCalls.delete(sessionId);
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'Stop',
        status: 'waiting_for_input',
        pid: process.pid
      });
    }
  }, { global: true });

  ctx.on('session/disposed', (session) => {
    activeToolCalls.delete(session.id);
    log('session/disposed: ' + (session.id || '').slice(0, 8));
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionEnd',
      status: 'ended',
      pid: process.pid
    });
  }, { global: true });
}
"""

        try? pkgJsonContent.write(toFile: pkgJsonPath, atomically: true, encoding: .utf8)
        try? cordisPatchContent.write(toFile: cordisPatchPath, atomically: true, encoding: .utf8)
        try? indexJsContent.write(toFile: indexPath, atomically: true, encoding: .utf8)

        // Ensure symlinks exist in node_modules
        let webNodeModules = dshDir + "/profiles/web/node_modules"
        if fm.fileExists(atPath: webNodeModules) {
            let symlinkPath = webNodeModules + "/dsh-vibe-notch"
            try? fm.removeItem(atPath: symlinkPath)
            try? fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: "../../../plugins/dsh-vibe-notch")
        }

        let profilesNodeModules = dshDir + "/profiles/node_modules"
        if fm.fileExists(atPath: profilesNodeModules) {
            let symlinkPath = profilesNodeModules + "/dsh-vibe-notch"
            try? fm.removeItem(atPath: symlinkPath)
            try? fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: "../plugins/dsh-vibe-notch")
        }

        let profilePath = dshDir + "/profiles/web/package.json"
        guard fm.fileExists(atPath: profilePath),
              let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
              var profileJson = (try? JSONSerialization.jsonObject(with: profileData)) as? [String: Any] else {
            return
        }

        var deps = profileJson["dependencies"] as? [String: Any] ?? [:]
        var dshObj = profileJson["dsh"] as? [String: Any] ?? [:]
        var profileObj = dshObj["profile"] as? [String: Any] ?? [:]
        var bundles = profileObj["bundles"] as? [String] ?? []

        var modified = false
        if deps["dsh-vibe-notch"] == nil && deps["@omdsh-dev/dsh-vibe-notch"] == nil {
            deps["dsh-vibe-notch"] = "link:" + pluginDir
            profileJson["dependencies"] = deps
            modified = true
        }

        if !bundles.contains("dsh-vibe-notch") && !bundles.contains("@omdsh-dev/dsh-vibe-notch") {
            bundles.append("dsh-vibe-notch")
            profileObj["bundles"] = bundles
            dshObj["profile"] = profileObj
            profileJson["dsh"] = dshObj
            modified = true
        }

        if modified,
           let updatedData = try? JSONSerialization.data(withJSONObject: profileJson, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: URL(fileURLWithPath: profilePath))
        }
    }

    /// Installs Codex Desktop hooks into ~/.codex/hooks, ~/.codex/hooks.json, and ~/.codex/config.toml
    static func installCodexHooksIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let codexDir = home + "/.codex"
        guard fm.fileExists(atPath: codexDir) else { return }

        let hooksDir = URL(fileURLWithPath: codexDir + "/hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let hooksJsonFile = URL(fileURLWithPath: codexDir + "/hooks.json")
        let bridgeScript = URL(fileURLWithPath: codexDir + "/codex_notify_bridge.py")

        try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        if let bundledHook = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            try? fm.removeItem(at: pythonScript)
            try? fm.copyItem(at: bundledHook, to: pythonScript)
            try? fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        if let bundledBridge = Bundle.main.url(forResource: "codex_notify_bridge", withExtension: "py") {
            try? fm.removeItem(at: bridgeScript)
            try? fm.copyItem(at: bundledBridge, to: bridgeScript)
            try? fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: bridgeScript.path
            )
        }

        let python = detectPython()
        let command = "\(python) '\(pythonScript.path)'"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksJsonFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let codexEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
            ("PostCompact", preCompactConfig)
        ]

        for (event, config) in codexEvents {
            hooks[event] = config
        }

        json["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksJsonFile)
        }

        updateCodexConfigTomlIfNeeded()
    }

    /// Updates ~/.codex/config.toml to ensure notify is configured with the bridge script.
    static func updateCodexConfigTomlIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let configPath = home + "/.codex/config.toml"
        guard fm.fileExists(atPath: configPath) else { return }

        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let bridgeScriptPath = home + "/.codex/codex_notify_bridge.py"
        let notifyLine = "notify = [\"python3\", \"\(bridgeScriptPath)\"]"

        if content.contains("codex_notify_bridge.py") {
            return
        }

        var lines = content.components(separatedBy: "\n")
        var replaced = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("notify") && trimmed.contains("=") {
                lines[i] = notifyLine
                replaced = true
                break
            }
        }

        if !replaced {
            var insertIndex = 0
            for (i, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    insertIndex = i
                    break
                }
            }
            lines.insert(notifyLine, at: insertIndex)
        }

        let updatedContent = lines.joined(separatedBy: "\n")
        try? updatedContent.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
