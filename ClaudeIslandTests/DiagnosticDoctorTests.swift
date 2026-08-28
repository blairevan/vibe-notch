import Foundation
import XCTest
@testable import Vibe_Notch

@MainActor
final class DiagnosticDoctorTests: XCTestCase {
    func testDoctorReportGeneratesValidItems() async throws {
        let mockStore = MockCredentialStore(credentials: DingTalkCredentials(token: "test-token", signingSecret: "test-sec"))
        let doctor = DiagnosticDoctor(credentialStore: mockStore)

        let report = await doctor.runDiagnostics()

        XCTAssertFalse(report.items.isEmpty)
        XCTAssertTrue(report.items.contains { $0.id == "socket-server" })
        XCTAssertTrue(report.items.contains { $0.id == "claude-hooks" || $0.id == "codex-integration" || $0.id == "dingtalk-creds" })
    }

    func testDoctorHandlesEmptyCredentials() async throws {
        let mockStore = MockCredentialStore(credentials: .empty)
        let doctor = DiagnosticDoctor(credentialStore: mockStore)

        let report = await doctor.runDiagnostics()

        let credItem = report.items.first { $0.id == "dingtalk-creds" }
        XCTAssertNotNil(credItem)
        if case .warning(let reason) = credItem?.status {
            XCTAssertTrue(reason.contains("Token empty"))
        } else {
            XCTFail("Expected warning status for empty token")
        }
    }
}

@MainActor
private final class MockCredentialStore: DingTalkCredentialStoring {
    var credentials: DingTalkCredentials

    init(credentials: DingTalkCredentials = .empty) {
        self.credentials = credentials
    }

    func load() throws -> DingTalkCredentials {
        credentials
    }

    func save(_ credentials: DingTalkCredentials) throws {
        self.credentials = credentials
    }

    func clear() throws {
        self.credentials = .empty
    }
}
