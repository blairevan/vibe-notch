import AppKit
import Foundation

/// Routes clicks to the originating GUI app or live terminal without spawning a new agent.
@MainActor
enum SessionFocusService {
    /// Focus a session, falling back from an exact tmux pane to its terminal application.
    static func focus(
        _ session: SessionState,
        activateApplication: @MainActor (String) async -> Bool = activate(bundleIdentifier:)
    ) async -> Bool {
        if let source = session.antigravitySource {
            if let bundle = source.bundleIdentifier {
                return await activateApplication(bundle)
            }
            guard source == .cli else { return false }
            if session.isInTmux, let pid = session.pid,
                await YabaiController.shared.focusWindow(forClaudePid: pid)
            {
                return true
            }
            guard let pid = session.pid else { return false }
            let tree = ProcessTreeBuilder.shared.buildTree()
            guard
                let terminalPID = ProcessTreeBuilder.shared.findTerminalPid(
                    forProcess: pid, tree: tree)
            else {
                return false
            }
            let windows = await WindowFinder.shared.getAllWindows()
            if let window = windows.first(where: { $0.pid == terminalPID }),
                await WindowFocuser.shared.focusWindow(id: window.id)
            {
                return true
            }
            return NSRunningApplication(processIdentifier: pid_t(terminalPID))?.activate() ?? false
        }
        if let pid = session.pid {
            return await YabaiController.shared.focusWindow(forClaudePid: pid)
        }
        return await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
    }

    /// Activate only the selected product, including launching it if it is no longer running.
    private static func activate(bundleIdentifier: String) async -> Bool {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            return app.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return false }
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }

    /// Explain a failed focus attempt without creating a replacement terminal session.
    static func focusOrExplain(_ session: SessionState) async {
        guard !(await focus(session)) else { return }
        let alert = NSAlert()
        alert.messageText = "无法定位原会话"
        alert.informativeText =
            "原应用或终端窗口可能已经关闭，请手动切换到 \(session.antigravitySource?.label ?? "原终端")。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
