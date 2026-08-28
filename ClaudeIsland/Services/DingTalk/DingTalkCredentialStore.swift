import Foundation

/// Credentials required by a DingTalk custom group robot.
struct DingTalkCredentials: Codable, Equatable, Sendable {
    let token: String
    let signingSecret: String

    /// Empty credentials used when no local credential file exists.
    static let empty = DingTalkCredentials(token: "", signingSecret: "")

    /// Returns credentials with surrounding whitespace removed.
    var trimmed: DingTalkCredentials {
        DingTalkCredentials(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            signingSecret: signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Abstracts credential persistence for production and tests.
@MainActor
protocol DingTalkCredentialStoring {
    /// Loads the saved robot credentials or an empty value.
    func load() throws -> DingTalkCredentials

    /// Atomically saves both robot credential fields.
    func save(_ credentials: DingTalkCredentials) throws

    /// Removes all saved robot credentials.
    func clear() throws
}

/// Minimal binary-data interface backed by an owner-only local file in production.
@MainActor
protocol DingTalkCredentialFileAccessing {
    /// Reads the saved credential data when present.
    func readData() throws -> Data?

    /// Atomically replaces the complete credential data value.
    func writeData(_ data: Data) throws

    /// Removes the credential data value when present.
    func deleteData() throws
}

/// Errors produced while locating or decoding DingTalk credentials.
enum DingTalkCredentialStoreError: Error, Equatable, LocalizedError {
    case invalidData
    case storageUnavailable

    /// A user-facing description that contains no credential material.
    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Saved DingTalk credentials could not be read."
        case .storageUnavailable:
            return "The DingTalk credential file location is unavailable."
        }
    }
}

/// Stores DingTalk credentials as one Codable value in an owner-only local file.
@MainActor
final class DingTalkCredentialStore: DingTalkCredentialStoring {
    static let shared = DingTalkCredentialStore()

    private let fileAccess: DingTalkCredentialFileAccessing

    /// Creates a store using the local application-support file by default.
    init(fileAccess: DingTalkCredentialFileAccessing? = nil) {
        self.fileAccess = fileAccess ?? LocalDingTalkCredentialFileAccess()
    }

    /// Loads and decodes the complete credential value.
    func load() throws -> DingTalkCredentials {
        guard let data = try fileAccess.readData() else {
            return .empty
        }
        do {
            return try JSONDecoder().decode(DingTalkCredentials.self, from: data)
        } catch {
            throw DingTalkCredentialStoreError.invalidData
        }
    }

    /// Trims and atomically saves the complete credential value.
    func save(_ credentials: DingTalkCredentials) throws {
        let data = try JSONEncoder().encode(credentials.trimmed)
        try fileAccess.writeData(data)
    }

    /// Removes the complete credential value.
    func clear() throws {
        try fileAccess.deleteData()
    }

    /// Synchronizes the runtime enabled preference with the presence of valid credentials.
    /// If valid credentials exist on disk, auto-enables the switch to prevent silent non-delivery.
    func syncEnabledState() {
        do {
            let credentials = try load()
            if !credentials.token.isEmpty {
                if !AppSettings.dingTalkEnabled {
                    AppSettings.dingTalkEnabled = true
                }
            }
        } catch {
            // Ignore error during startup sync
        }
    }

}

/// Reads and atomically writes DingTalk credentials in Application Support.
@MainActor
final class LocalDingTalkCredentialFileAccess: DingTalkCredentialFileAccessing {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    private let explicitFileURL: URL?
    private let fileManager: FileManager

    /// Creates the production file adapter or accepts an explicit URL for tests.
    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        explicitFileURL = fileURL
        self.fileManager = fileManager
    }

    /// Reads credential data and repairs owner-only permissions when the file exists.
    func readData() throws -> Data? {
        let fileURL = try resolvedFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try applyOwnerOnlyPermissions(to: fileURL)
        return try Data(contentsOf: fileURL)
    }

    /// Writes a synchronized mode-0600 temporary file and atomically installs it.
    func writeData(_ data: Data) throws {
        let fileURL = try resolvedFileURL()
        try ensureCredentialDirectory(at: fileURL.deletingLastPathComponent())

        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".dingtalk-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: Self.filePermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try applyOwnerOnlyPermissions(to: fileURL)
    }

    /// Deletes the local credential file and treats an absent file as success.
    func deleteData() throws {
        let fileURL = try resolvedFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    /// Resolves the explicit test URL or the production application-support URL.
    private func resolvedFileURL() throws -> URL {
        if let explicitFileURL {
            return explicitFileURL
        }
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DingTalkCredentialStoreError.storageUnavailable
        }
        return applicationSupportURL
            .appendingPathComponent("Vibe Notch", isDirectory: true)
            .appendingPathComponent("dingtalk.json", isDirectory: false)
    }

    /// Creates the credential directory and applies mode 0700 to it.
    private func ensureCredentialDirectory(at directoryURL: URL) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directoryURL.path
        )
    }

    /// Applies mode 0700 to the parent directory and mode 0600 to the file.
    private func applyOwnerOnlyPermissions(to fileURL: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: fileURL.path
        )
    }
}
