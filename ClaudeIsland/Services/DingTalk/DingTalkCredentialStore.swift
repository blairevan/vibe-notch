import Foundation
import Security

/// Credentials required by a DingTalk custom group robot.
struct DingTalkCredentials: Codable, Equatable, Sendable {
    let token: String
    let signingSecret: String

    /// Empty credentials used when no Keychain item exists.
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

/// Minimal binary-data interface backed by macOS Keychain in production.
@MainActor
protocol DingTalkKeychainAccessing {
    /// Reads the saved credential data when present.
    func readData() throws -> Data?

    /// Replaces the complete credential data value.
    func writeData(_ data: Data) throws

    /// Removes the credential data value when present.
    func deleteData() throws
}

/// Errors produced while encoding or accessing DingTalk credentials.
enum DingTalkCredentialStoreError: Error, LocalizedError {
    case invalidData
    case keychainStatus(OSStatus)

    /// A user-facing description that contains no credential material.
    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Saved DingTalk credentials could not be read."
        case .keychainStatus(let status):
            return "Keychain operation failed (\(status))."
        }
    }
}

/// Stores DingTalk credentials as one Codable Keychain item.
@MainActor
final class DingTalkCredentialStore: DingTalkCredentialStoring {
    static let shared = DingTalkCredentialStore()

    private let keychain: DingTalkKeychainAccessing

    /// Creates a store using the system Keychain by default.
    init(keychain: DingTalkKeychainAccessing? = nil) {
        self.keychain = keychain ?? SecurityDingTalkKeychainAccess()
    }

    /// Loads and decodes the complete credential value.
    func load() throws -> DingTalkCredentials {
        guard let data = try keychain.readData() else {
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
        try keychain.writeData(data)
    }

    /// Removes the complete credential value.
    func clear() throws {
        try keychain.deleteData()
    }
}

/// Direct adapter for the macOS Security framework Keychain APIs.
@MainActor
final class SecurityDingTalkKeychainAccess: DingTalkKeychainAccessing {
    private let service = "com.celestial.ClaudeIsland.dingtalk"
    private let account = "robot-credentials"

    /// Creates the system Keychain adapter.
    init() {}

    /// Reads one generic-password data value.
    func readData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw DingTalkCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw DingTalkCredentialStoreError.invalidData
        }
        return data
    }

    /// Updates the existing item or inserts it when absent.
    func writeData(_ data: Data) throws {
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw DingTalkCredentialStoreError.keychainStatus(updateStatus)
        }

        var newItem = baseQuery
        newItem[kSecValueData] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DingTalkCredentialStoreError.keychainStatus(addStatus)
        }
    }

    /// Deletes the item and treats an absent value as success.
    func deleteData() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DingTalkCredentialStoreError.keychainStatus(status)
        }
    }

    /// Base generic-password query shared by all operations.
    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
