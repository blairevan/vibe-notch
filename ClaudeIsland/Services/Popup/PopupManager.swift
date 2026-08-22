//
//  PopupManager.swift
//  ClaudeIsland
//
//  Manages popup alerts for permission requests
//

import AppKit
import Foundation
import os.log

/// Manager for showing popup alerts when permission requests are received
class PopupManager {
    static let shared = PopupManager()

    private let logger = Logger(subsystem: "com.claudeisland", category: "Popup")

    /// Track shown popups to avoid duplicates (key: toolUseId)
    private var shownPopups: Set<String> = []

    private init() {}

    /// Show a popup alert for a permission request
    func showPermissionPopup(
        sessionId: String,
        toolName: String,
        toolInput: [String: AnyCodable]?,
        toolUseId: String
    ) {
        // Check if popup is enabled
        guard AppSettings.showPopupOnPermissionRequest else { return }

        // Avoid showing duplicate popups for the same tool use
        guard !shownPopups.contains(toolUseId) else { return }
        shownPopups.insert(toolUseId)

        // Clean up old entries after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.shownPopups.remove(toolUseId)
        }

        // Format tool input for display
        let inputDescription = formatToolInput(toolName: toolName, toolInput: toolInput)

        // Show popup on main thread
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(
                toolName: toolName,
                inputDescription: inputDescription,
                sessionId: sessionId,
                toolUseId: toolUseId
            )
        }
    }

    private func showAlert(
        toolName: String,
        inputDescription: String,
        sessionId: String,
        toolUseId: String
    ) {
        let alert = NSAlert()
        alert.messageText = "Permission Request"
        alert.informativeText = "Claude wants to use \(toolName)\n\n\(inputDescription)"
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Permission")

        // Add buttons
        alert.addButton(withTitle: "View in Notch")
        alert.addButton(withTitle: "Dismiss")

        // Make the alert float on top
        alert.window.level = .floating

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // User clicked "View in Notch" - activate the app
            NSApplication.shared.activate(ignoringOtherApps: true)
            logger.info("User clicked View in Notch for tool: \(toolName, privacy: .public)")
        }
    }

    private func formatToolInput(toolName: String, toolInput: [String: AnyCodable]?) -> String {
        guard let input = toolInput else {
            return "No input parameters"
        }

        switch toolName {
        case "Bash":
            if let command = input["command"]?.value as? String {
                let truncated = command.count > 100 ? String(command.prefix(100)) + "..." : command
                return "Command: \(truncated)"
            }
        case "Read", "Edit", "Write":
            if let filePath = input["file_path"]?.value as? String {
                return "File: \(filePath)"
            }
        case "Grep":
            if let pattern = input["pattern"]?.value as? String {
                return "Pattern: \(pattern)"
            }
        case "Glob":
            if let path = input["path"]?.value as? String {
                return "Path: \(path)"
            }
        default:
            break
        }

        // Generic fallback: show first few key-value pairs
        let pairs = input.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return pairs.isEmpty ? "No details" : pairs
    }
}
