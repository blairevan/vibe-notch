//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// Display presentation modes for the notch UI.
enum DisplayMode: String, CaseIterable {
    case dynamicIsland = "Dynamic Island"
    case menuBarOnly = "Menu Bar Only"

    var localizedLabel: String {
        switch self {
        case .dynamicIsland:
            return "Dynamic Island (Floating)"
        case .menuBarOnly:
            return "Menu Bar Only (Icon Only)"
        }
    }
}

extension Notification.Name {
    static let displayModeDidChange = Notification.Name("com.claudeisland.displayModeDidChange")
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let codexDirectoryPath = "codexDirectoryPath"
        static let dshDirectoryPath = "dshDirectoryPath"
        static let showPopupOnPermissionRequest = "showPopupOnPermissionRequest"
        static let dingTalkEnabled = "dingTalkEnabled"
        static let displayMode = "displayMode"
    }

    // MARK: - Display Mode

    /// Current display presentation mode (Dynamic Island vs Menu Bar Only).
    static var displayMode: DisplayMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.displayMode),
                  let mode = DisplayMode(rawValue: rawValue) else {
                return .dynamicIsland
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.displayMode)
            NotificationCenter.default.post(name: .displayModeDidChange, object: nil)
        }
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Popup on Permission Request

    /// Whether to show a popup alert when a permission request is received
    static var showPopupOnPermissionRequest: Bool {
        get {
            defaults.bool(forKey: Keys.showPopupOnPermissionRequest)
        }
        set {
            defaults.set(newValue, forKey: Keys.showPopupOnPermissionRequest)
        }
    }

    // MARK: - DingTalk Notifications

    /// Whether session events may be sent to the configured DingTalk robot.
    static var dingTalkEnabled: Bool {
        get {
            defaults.bool(forKey: Keys.dingTalkEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.dingTalkEnabled)
        }
    }

    // MARK: - Workspace & Directories

    /// Custom Claude configuration directory.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    /// Custom Codex configuration directory path.
    static var codexDirectoryPath: String {
        get {
            let value = defaults.string(forKey: Keys.codexDirectoryPath) ?? ""
            return value.isEmpty ? (FileManager.default.homeDirectoryForCurrentUser.path + "/.codex") : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.codexDirectoryPath)
        }
    }

    /// Custom DeepSeek Harness (DSH) directory path.
    static var dshDirectoryPath: String {
        get {
            let value = defaults.string(forKey: Keys.dshDirectoryPath) ?? ""
            return value.isEmpty ? (FileManager.default.homeDirectoryForCurrentUser.path + "/.dsh") : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.dshDirectoryPath)
        }
    }
}
