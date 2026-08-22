import Foundation
import XCTest
@testable import Vibe_Notch

/// Verifies credential encoding and owner-only local-file persistence.
@MainActor
final class DingTalkCredentialStoreTests: XCTestCase {
    /// Verifies the complete credential value round-trips through Codable.
    func testCredentialsRoundTripThroughCodec() throws {
        let credentials = DingTalkCredentials(token: "token", signingSecret: "secret")

        let data = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(DingTalkCredentials.self, from: data)

        XCTAssertEqual(decoded, credentials)
    }

    /// Verifies an absent credential file is represented by empty credentials.
    func testMissingFileReturnsEmptyCredentials() throws {
        try withTemporaryStore { store, _, _ in
            XCTAssertEqual(try store.load(), .empty)
        }
    }

    /// Verifies saving trims and replaces both sensitive fields as one value.
    func testSaveTrimsAndLoadsOneCredentialValue() throws {
        try withTemporaryStore { store, _, _ in
            try store.save(DingTalkCredentials(token: "old-token", signingSecret: "old-secret"))
            let credentials = DingTalkCredentials(
                token: "  new-token\n",
                signingSecret: " new-secret "
            )

            try store.save(credentials)

            XCTAssertEqual(
                try store.load(),
                DingTalkCredentials(token: "new-token", signingSecret: "new-secret")
            )
        }
    }

    /// Verifies the application directory and credential file are owner-only.
    func testSaveAppliesOwnerOnlyPermissions() throws {
        try withTemporaryStore { store, directoryURL, fileURL in
            try store.save(DingTalkCredentials(token: "token", signingSecret: "secret"))

            XCTAssertEqual(try permissions(at: directoryURL), 0o700)
            XCTAssertEqual(try permissions(at: fileURL), 0o600)
        }
    }

    /// Verifies loading repairs permissions that became more permissive.
    func testLoadRepairsOwnerOnlyPermissions() throws {
        try withTemporaryStore { store, directoryURL, fileURL in
            try store.save(DingTalkCredentials(token: "token", signingSecret: "secret"))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directoryURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fileURL.path
            )

            _ = try store.load()

            XCTAssertEqual(try permissions(at: directoryURL), 0o700)
            XCTAssertEqual(try permissions(at: fileURL), 0o600)
        }
    }

    /// Verifies malformed JSON is rejected without returning partial credentials.
    func testMalformedFileThrowsInvalidData() throws {
        try withTemporaryStore { store, directoryURL, fileURL in
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("not-json".utf8).write(to: fileURL)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? DingTalkCredentialStoreError, .invalidData)
            }
        }
    }

    /// Verifies a failed write does not replace the previously stored value.
    func testFailedSavePreservesExistingCredentials() throws {
        let original = DingTalkCredentials(token: "original", signingSecret: "secret")
        let fileAccess = InMemoryCredentialFileAccess(data: try JSONEncoder().encode(original))
        fileAccess.writeError = TestFileError.writeFailed
        let store = DingTalkCredentialStore(fileAccess: fileAccess)

        XCTAssertThrowsError(
            try store.save(DingTalkCredentials(token: "replacement", signingSecret: ""))
        )
        XCTAssertEqual(try store.load(), original)
    }

    /// Verifies clear removes the complete credential file.
    func testClearRemovesCredentialFile() throws {
        try withTemporaryStore { store, _, fileURL in
            try store.save(DingTalkCredentials(token: "token", signingSecret: "secret"))

            try store.clear()

            XCTAssertEqual(try store.load(), .empty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    /// Runs a test body with an isolated local credential store and removes it afterward.
    private func withTemporaryStore(
        _ body: (
            DingTalkCredentialStore,
            URL,
            URL
        ) throws -> Void
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeNotchTests-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Vibe Notch", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("dingtalk.json", isDirectory: false)
        let fileAccess = LocalDingTalkCredentialFileAccess(fileURL: fileURL)
        let store = DingTalkCredentialStore(fileAccess: fileAccess)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try body(store, directoryURL, fileURL)
    }

    /// Returns the POSIX permission bits for a filesystem item.
    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue
    }
}

/// Deterministic file-access substitute for atomic failure tests.
@MainActor
private final class InMemoryCredentialFileAccess: DingTalkCredentialFileAccessing {
    var writeError: Error?
    private var data: Data?

    /// Creates an adapter with optional existing data.
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
        self.data = data
    }

    /// Removes the in-memory value.
    func deleteData() throws {
        data = nil
    }
}

/// Failures injected by the in-memory file-access substitute.
private enum TestFileError: Error {
    case writeFailed
}
