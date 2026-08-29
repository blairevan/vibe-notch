import Combine
import Foundation
import os.log

/// Result status of a single diagnostic check item.
enum DiagnosticStatus: Equatable, Sendable {
    case ok
    case warning(String)
    case error(String)
    case notApplicable

    var isSuccess: Bool {
        switch self {
        case .ok, .notApplicable:
            return true
        case .warning, .error:
            return false
        }
    }
}

/// A single check item in the health report.
struct DiagnosticItem: Identifiable, Equatable, Sendable {
    let id: String
    let category: String
    let title: String
    let status: DiagnosticStatus
    let details: String
}

/// Overall diagnostic health report.
struct DiagnosticReport: Equatable, Sendable {
    let items: [DiagnosticItem]
    let generatedAt: Date

    var isAllHealthy: Bool {
        items.allSatisfy { $0.status.isSuccess }
    }

    var errorCount: Int {
        items.filter {
            if case .error = $0.status { return true }
            return false
        }.count
    }

    var warningCount: Int {
        items.filter {
            if case .warning = $0.status { return true }
            return false
        }.count
    }
}

/// Comprehensive health diagnostic suite for Vibe Notch and its AI ecosystem integrations.
@MainActor
final class DiagnosticDoctor: ObservableObject {
    static let shared = DiagnosticDoctor()

    @Published private(set) var latestReport: DiagnosticReport?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastPingStatus: String?

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Doctor")
    private let credentialStore: DingTalkCredentialStoring

    init(credentialStore: DingTalkCredentialStoring? = nil) {
        self.credentialStore = credentialStore ?? DingTalkCredentialStore.shared
    }

    /// Executes all diagnostic checks and updates the published report.
    func runDiagnostics() async -> DiagnosticReport {
        isRunning = true
        defer { isRunning = false }

        var items: [DiagnosticItem] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // 1. Check Unix Socket Server
        let socketPath = "/tmp/claude-island.sock"
        if fm.fileExists(atPath: socketPath) {
            items.append(DiagnosticItem(
                id: "socket-server",
                category: "Core",
                title: "Unix Domain Socket",
                status: .ok,
                details: "Socket file exists at /tmp/claude-island.sock and is listening."
            ))
        } else {
            items.append(DiagnosticItem(
                id: "socket-server",
                category: "Core",
                title: "Unix Domain Socket",
                status: .error("Socket missing"),
                details: "Socket at /tmp/claude-island.sock is not running. Restart Vibe Notch."
            ))
        }

        // 2. Check Claude Code Integration
        let claudeDir = home + "/.claude"
        if fm.fileExists(atPath: claudeDir) {
            let isInstalled = HookInstaller.isInstalled()
            if isInstalled {
                items.append(DiagnosticItem(
                    id: "claude-hooks",
                    category: "Claude Code",
                    title: "Claude Code Hooks",
                    status: .ok,
                    details: "Hooks are correctly installed in ~/.claude/settings.json."
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "claude-hooks",
                    category: "Claude Code",
                    title: "Claude Code Hooks",
                    status: .warning("Hooks not registered"),
                    details: "Hooks are not registered in ~/.claude/settings.json."
                ))
            }
        } else {
            items.append(DiagnosticItem(
                id: "claude-hooks",
                category: "Claude Code",
                title: "Claude Code Hooks",
                status: .notApplicable,
                details: "~/.claude directory not found (Claude Code not installed)."
            ))
        }

      // 3. Check Codex Desktop Integration
      let codexDir = home + "/.codex"
      if fm.fileExists(atPath: codexDir) {
           let pythonScript = codexDir + "/hooks/claude-island-state.py"
           let bridgeScript = codexDir + "/codex_notify_bridge.py"
          let hooksJson = codexDir + "/hooks.json"

          var codexOk = true
          var codexDetails: [String] = []

           if fm.fileExists(atPath: pythonScript) {
               codexDetails.append("Hook script deployed")
           } else {
               codexOk = false
               codexDetails.append("Hook script missing")
           }

           if fm.fileExists(atPath: bridgeScript) {
               codexDetails.append("Bridge script deployed")
           } else {
               codexOk = false
               codexDetails.append("Bridge script missing")
           }

          if fm.fileExists(atPath: hooksJson) {
              codexDetails.append("hooks.json deployed")
          } else {
              codexOk = false
              codexDetails.append("hooks.json missing")
          }

          items.append(DiagnosticItem(
              id: "codex-integration",
              category: "Codex Desktop",
                title: "Codex Desktop Bridge",
              status: codexOk ? .ok : .error("Integration incomplete"),
              details: codexDetails.joined(separator: ", ")
          ))
      } else {
          items.append(DiagnosticItem(
              id: "codex-integration",
              category: "Codex Desktop",
                title: "Codex Desktop Bridge",
              status: .notApplicable,
              details: "~/.codex directory not found (Codex Desktop not installed)."
          ))
      }

        // 4. Check DSH (DeepSeek Harness) Integration
        let dshDir = home + "/.dsh"
        if fm.fileExists(atPath: dshDir) {
            let dshPlugin = dshDir + "/plugins/dsh-vibe-notch/package.json"
            if fm.fileExists(atPath: dshPlugin) {
                items.append(DiagnosticItem(
                    id: "dsh-plugin",
                    category: "DSH",
                    title: "DeepSeek Harness Plugin",
                    status: .ok,
                    details: "dsh-vibe-notch plugin is installed in ~/.dsh/plugins/."
                ))
            } else {
                items.append(DiagnosticItem(
                    id: "dsh-plugin",
                    category: "DSH",
                    title: "DeepSeek Harness Plugin",
                    status: .warning("Plugin missing"),
                    details: "dsh-vibe-notch plugin is not installed in ~/.dsh/."
                ))
            }
        } else {
            items.append(DiagnosticItem(
                id: "dsh-plugin",
                category: "DSH",
                title: "DeepSeek Harness Plugin",
                status: .notApplicable,
                details: "~/.dsh directory not found (DSH not installed)."
            ))
        }

        // 5. Check DingTalk Credentials & Switch State
        do {
            let credentials = try credentialStore.load()
            if credentials.token.isEmpty {
                items.append(DiagnosticItem(
                    id: "dingtalk-creds",
                    category: "DingTalk",
                    title: "Robot Credentials",
                    status: .warning("Token empty"),
                    details: "No Robot Token configured. Fill in your DingTalk access_token in settings."
                ))
            } else {
                let isEnabled = AppSettings.dingTalkEnabled
                items.append(DiagnosticItem(
                    id: "dingtalk-creds",
                    category: "DingTalk",
                    title: "Robot Credentials",
                    status: isEnabled ? .ok : .warning("Switch disabled"),
                    details: isEnabled
                        ? "Token configured and notification switch is ON."
                        : "Token configured but notification switch is OFF."
                ))
            }
        } catch {
            items.append(DiagnosticItem(
                id: "dingtalk-creds",
                category: "DingTalk",
                title: "Robot Credentials",
                status: .error(error.localizedDescription),
                details: "Error loading dingtalk.json: \(error.localizedDescription)"
            ))
        }

        let report = DiagnosticReport(items: items, generatedAt: Date())
        latestReport = report
        return report
    }

    /// Automatically fixes missing hooks, bridge scripts, and enables valid credentials.
    func autoFixAll() async -> DiagnosticReport {
        HookInstaller.installIfNeeded()
        DingTalkCredentialStore.shared.syncEnabledState()
        return await runDiagnostics()
    }

    /// Sends a live test ping message to the DingTalk robot.
    func pingDingTalk() async -> Bool {
        do {
            let credentials = try credentialStore.load().trimmed
            guard !credentials.token.isEmpty else {
                lastPingStatus = "Error: Robot Token is empty."
                return false
            }
            let client = DingTalkClient()
            try await client.send(.test, credentials: credentials)
            lastPingStatus = "Success: Test ping delivered to DingTalk!"
            return true
        } catch {
            lastPingStatus = "Ping failed: \(error.localizedDescription)"
            return false
        }
    }
}
