import Foundation
import XCTest
@testable import Vibe_Notch

/// Verifies DingTalk notifications derived from unified session snapshots.
@MainActor
final class DingTalkNotificationCoordinatorTests: XCTestCase {
    /// Verifies the initial snapshot seeds state without notifying.
    func testInitialWaitingSnapshotDoesNotNotify() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])

        XCTAssertTrue(recorder.messages.isEmpty)
    }

    /// Verifies a transition to waiting-for-input notifies exactly once.
    func testTransitionToWaitingForInputNotifiesOnce() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])

        XCTAssertEqual(recorder.messages.count, 1)
        XCTAssertEqual(recorder.messages.first?.title, "Vibe Notch - Task Completed")
    }

    /// Verifies a newly discovered waiting session is not mistaken for a completed task.
    func testNewWaitingSessionDoesNotNotifyUntilKnownTransition() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])
        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])

        XCTAssertEqual(recorder.messages.count, 1)
    }

    /// Verifies each permission tool identifier notifies only once.
    func testPermissionToolUseIdNotifiesOnce() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-1")])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-1")])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-2")])

        XCTAssertEqual(recorder.messages.count, 2)
        XCTAssertTrue(recorder.messages.allSatisfy { $0.title == "Vibe Notch - Permission Required" })
    }

    /// Verifies removing a session clears its permission deduplication state.
    func testRemovedSessionClearsDeduplicationState() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-1")])
        await coordinator.processSnapshot([])
        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-1")])

        XCTAssertEqual(recorder.messages.count, 2)
    }

    /// Verifies disabled notifications still advance state without sending.
    func testDisabledTransitionDoesNotSendOrBackfill() async {
        let recorder = MessageRecorder()
        var isEnabled = false
        let coordinator = makeCoordinator(recorder: recorder, isEnabled: { isEnabled })

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])
        isEnabled = true
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])

        XCTAssertTrue(recorder.messages.isEmpty)
    }

    /// Verifies messages include safe context but exclude paths and tool input.
    func testMessageContainsProjectNameButNotFullPathOrToolInput() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-private")])

        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("Project: vibe-notch"))
        XCTAssertTrue(text.contains("Tool: Bash"))
        XCTAssertFalse(text.contains("/Users/private/vibe-notch"))
        XCTAssertFalse(text.contains("private command"))
    }

    /// Creates a coordinator with deterministic credentials, time, and transport.
    private func makeCoordinator(
        recorder: MessageRecorder,
        isEnabled: @escaping () -> Bool = { true }
    ) -> DingTalkNotificationCoordinator {
        DingTalkNotificationCoordinator(
            credentialStore: TestCredentialStore(),
            isEnabled: isEnabled,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            send: recorder.send
        )
    }

    /// Creates a session with deterministic identity and project metadata.
    private func makeSession(phase: SessionPhase) -> SessionState {
        SessionState(
            sessionId: "session-1",
            cwd: "/Users/private/vibe-notch",
            projectName: "vibe-notch",
            phase: phase
        )
    }

    /// Creates a permission session containing intentionally private tool input.
    private func makePermissionSession(toolUseId: String) -> SessionState {
        makeSession(
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: toolUseId,
                    toolName: "Bash",
                    toolInput: ["command": AnyCodable("private command")],
                    receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        )
    }
}

/// Records coordinator output without making network requests.
@MainActor
private final class MessageRecorder {
    private(set) var messages: [DingTalkMessage] = []

    /// Records one outgoing message.
    func send(_ message: DingTalkMessage, credentials: DingTalkCredentials) async throws {
        XCTAssertFalse(credentials.token.isEmpty)
        messages.append(message)
    }
}

/// Supplies deterministic credentials to coordinator tests.
@MainActor
private final class TestCredentialStore: DingTalkCredentialStoring {
    /// Returns a configured test token.
    func load() throws -> DingTalkCredentials {
        DingTalkCredentials(token: "token", signingSecret: "")
    }

    /// Saves are not used by coordinator tests.
    func save(_ credentials: DingTalkCredentials) throws {}

    /// Clears are not used by coordinator tests.
    func clear() throws {}
}
