import Foundation
import XCTest
@testable import Vibe_Notch

/// Verifies credential encoding and Keychain-store behavior.
@MainActor
final class DingTalkCredentialStoreTests: XCTestCase {
    /// Verifies the complete credential value round-trips through Codable.
    func testCredentialsRoundTripThroughCodec() throws {
        let credentials = DingTalkCredentials(token: "token", signingSecret: "secret")

        let data = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(DingTalkCredentials.self, from: data)

        XCTAssertEqual(decoded, credentials)
    }

    /// Verifies an absent Keychain item is represented by empty credentials.
    func testEmptyStoreReturnsEmptyCredentials() throws {
        let keychain = InMemoryKeychainAccess()
        let store = DingTalkCredentialStore(keychain: keychain)

        XCTAssertEqual(try store.load(), .empty)
    }

    /// Verifies saving replaces both sensitive fields as one value.
    func testSaveAndLoadUseOneCredentialValue() throws {
        let keychain = InMemoryKeychainAccess()
        let store = DingTalkCredentialStore(keychain: keychain)
        let credentials = DingTalkCredentials(token: "new-token", signingSecret: "new-secret")

        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
        XCTAssertEqual(keychain.writeCount, 1)
    }

    /// Verifies a failed write does not replace the previously stored value.
    func testFailedSavePreservesExistingCredentials() throws {
        let original = DingTalkCredentials(token: "original", signingSecret: "secret")
        let keychain = InMemoryKeychainAccess(data: try JSONEncoder().encode(original))
        keychain.writeError = TestKeychainError.writeFailed
        let store = DingTalkCredentialStore(keychain: keychain)

        XCTAssertThrowsError(try store.save(DingTalkCredentials(token: "replacement", signingSecret: "")))
        XCTAssertEqual(try store.load(), original)
    }

    /// Verifies clear removes the complete credential value.
    func testClearRemovesCredentials() throws {
        let credentials = DingTalkCredentials(token: "token", signingSecret: "secret")
        let keychain = InMemoryKeychainAccess(data: try JSONEncoder().encode(credentials))
        let store = DingTalkCredentialStore(keychain: keychain)

        try store.clear()

        XCTAssertEqual(try store.load(), .empty)
        XCTAssertEqual(keychain.deleteCount, 1)
    }
}

/// Deterministic Keychain substitute for unit tests.
@MainActor
private final class InMemoryKeychainAccess: DingTalkKeychainAccessing {
    var writeError: Error?
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private var data: Data?

    /// Creates a store with optional existing data.
    init(data: Data? = nil) {
        self.data = data
    }

    /// Returns the current in-memory value.
    func readData() throws -> Data? {
        data
    }

    /// Replaces the value unless a configured failure is present.
    func writeData(_ data: Data) throws {
        if let writeError {
            throw writeError
        }
        writeCount += 1
        self.data = data
    }

    /// Removes the in-memory value.
    func deleteData() throws {
        deleteCount += 1
        data = nil
    }
}

/// Failures injected by the in-memory Keychain substitute.
private enum TestKeychainError: Error {
    case writeFailed
}
