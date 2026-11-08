import Foundation
import os.log

/// Installs an isolated hook namespace shared by agy, Antigravity, and its IDE.
enum AntigravityHookInstaller {
    private static let key = "vibe-notch-antigravity"
    private static let logger = Logger(subsystem: "com.claudeisland", category: "Antigravity")

    /// Merge configuration without discarding other hooks or resetting an explicit disable.
    static func configuration(merging data: Data?, bridgePath: String, pythonPath: String) throws
        -> Data
    {
        var root =
            try data.map { try JSONDecoder().decode([String: AnyCodable].self, from: $0) } ?? [:]
        let existing = root[key]?.value as? [String: Any]
        let command = "\(shellQuote(pythonPath)) \(shellQuote(bridgePath))"
        let definition = Definition(
            enabled: existing?["enabled"] as? Bool ?? true,
            sessionStart: [Handler(command: "\(command) SessionStart")],
            preInvocation: [Handler(command: "\(command) PreInvocation")],
            postToolUse: [ToolHandler(hooks: [Handler(command: "\(command) PostToolUse")])],
            stop: [Handler(command: "\(command) Stop")]
        )
        root[key] = try JSONDecoder().decode(
            AnyCodable.self, from: JSONEncoder().encode(definition))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(root)
    }

    /// Install bundled script and atomically merge global hooks; malformed JSON is left untouched.
    static func installIfNeeded() {
        let fm = FileManager.default
        let gemini = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        guard fm.fileExists(atPath: gemini.path),
            let bundled = Bundle.main.url(forResource: "antigravity_bridge", withExtension: "py")
        else { return }
        guard
            let python = [
                "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
            ]
            .first(where: { fm.isExecutableFile(atPath: $0) })
        else {
            logger.error("Python 3 unavailable; Antigravity integration was not installed")
            return
        }
        do {
            try install(in: gemini, bridgeData: Data(contentsOf: bundled), pythonPath: python)
        } catch {
            logger.error(
                "Antigravity hook installation failed; existing configuration was preserved")
        }
    }

    /// Install into an explicit data root, allowing filesystem verification in an isolated directory.
    static func install(in gemini: URL, bridgeData: Data, pythonPath: String) throws {
        let fm = FileManager.default
        let directory = gemini.appendingPathComponent("config/vibe-notch", isDirectory: true)
        let configURL = gemini.appendingPathComponent("config/hooks.json")
        let bridge = directory.appendingPathComponent("antigravity_bridge.py")
        let previous = fm.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : nil
        let merged = try configuration(
            merging: previous, bridgePath: bridge.path, pythonPath: pythonPath)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try bridgeData.write(to: bridge, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        if previous != merged { try merged.write(to: configURL, options: .atomic) }
    }

    /// Report configuration health without touching any host settings.
    static func diagnostic() -> DiagnosticItem {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".gemini")
        let config = gemini.appendingPathComponent("config/hooks.json")
        let bridge = gemini.appendingPathComponent("config/vibe-notch/antigravity_bridge.py")
        let status: DiagnosticStatus
        if !FileManager.default.fileExists(atPath: gemini.path) {
            status = .notApplicable
        } else {
            do {
                let root = try JSONDecoder().decode(
                    [String: AnyCodable].self, from: Data(contentsOf: config))
                let own = root[key]?.value as? [String: Any]
                if own?["enabled"] as? Bool == false {
                    status = .warning("Antigravity hooks disabled")
                } else if own?["Stop"] != nil && own?["PreInvocation"] != nil
                    && FileManager.default.isExecutableFile(atPath: bridge.path)
                {
                    status = .ok
                } else {
                    status = .warning("Antigravity integration incomplete")
                }
            } catch {
                status = .warning("Antigravity hooks missing or invalid")
            }
        }
        return DiagnosticItem(
            id: "antigravity-integration", category: "Antigravity",
            title: "agy / Antigravity / Antigravity IDE",
            status: status,
            details:
                "Shared lifecycle hooks in ~/.gemini/config/hooks.json; no conversation content is collected."
        )
    }

    /// Remove only the namespace and script owned by this integration.
    static func uninstall() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".gemini/config")
        let configURL = directory.appendingPathComponent("hooks.json")
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                var root = try JSONDecoder().decode(
                    [String: AnyCodable].self, from: Data(contentsOf: configURL))
                root.removeValue(forKey: key)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(root).write(to: configURL, options: .atomic)
            }
            let bridge = directory.appendingPathComponent("vibe-notch/antigravity_bridge.py")
            if FileManager.default.fileExists(atPath: bridge.path) {
                try FileManager.default.removeItem(at: bridge)
            }
        } catch {
            logger.error("Antigravity hook removal failed; unrelated hooks were preserved")
        }
    }

    /// Quote shell arguments, including user paths containing spaces or apostrophes.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Official command handler with a short host-enforced timeout.
    private struct Handler: Encodable {
        let type = "command"
        let command: String
        let timeout = 2
    }

    /// Tool lifecycle hooks use a matcher wrapper in the official schema.
    private struct ToolHandler: Encodable {
        let matcher = ".*"
        let hooks: [Handler]
    }

    /// One named hook definition; lifecycle handlers do not use matcher wrappers.
    private struct Definition: Encodable {
        let enabled: Bool
        let sessionStart: [Handler]
        let preInvocation: [Handler]
        let postToolUse: [ToolHandler]
        let stop: [Handler]

        enum CodingKeys: String, CodingKey {
            case enabled
            case sessionStart = "SessionStart"
            case preInvocation = "PreInvocation"
            case postToolUse = "PostToolUse"
            case stop = "Stop"
        }
    }
}
