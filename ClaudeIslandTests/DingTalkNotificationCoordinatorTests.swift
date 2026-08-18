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

    /// Verifies messages include rich safe context and blockquoted summaries.
    func testMessageContainsProjectNameAndRichFields() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        let session = SessionState(
            sessionId: "session-1",
            cwd: "/Users/private/vibe-notch",
            projectName: "vibe-notch",
            pid: 12345,
            tty: "ttys002",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: "优化钉钉通知",
                lastMessage: "任务已顺利完成，欢迎进行测试。",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "修改通知内容",
                lastUserMessageDate: nil,
                lastUserMessage: "请帮我增加本轮任务展示"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - 85) // 85s duration
        )

        await coordinator.processSnapshot([session])
        var waitingSession = session
        waitingSession.phase = .waitingForInput
        await coordinator.processSnapshot([waitingSession])

        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("vibe-notch"))
        XCTAssertTrue(text.contains("优化钉钉通知"))
        XCTAssertTrue(text.contains("请帮我增加本轮任务展示"))
        XCTAssertTrue(text.contains("任务已顺利完成，欢迎进行测试。"))
        XCTAssertTrue(text.contains("1分25秒"))
        XCTAssertTrue(text.contains("ttys002 (PID: 12345)"))
        XCTAssertFalse(text.contains("/Users/private/vibe-notch"))
    }

    /// Verifies long assistant response is truncated head-200 and tail-200 with ellipsis.
    func testLongAssistantResultTruncation() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        let head = String(repeating: "A", count: 250)
        let tail = String(repeating: "B", count: 250)
        let longMessage = head + tail // 500 chars

        let session = SessionState(
            sessionId: "session-1",
            cwd: "/Users/private/vibe-notch",
            projectName: "vibe-notch",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: longMessage,
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "首条用户指令",
                lastUserMessageDate: nil
            )
        )

        await coordinator.processSnapshot([session])
        var waitingSession = session
        waitingSession.phase = .waitingForInput
        await coordinator.processSnapshot([waitingSession])

        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains(String(repeating: "A", count: 100)))
        XCTAssertTrue(text.contains("..."))
        XCTAssertTrue(text.contains(String(repeating: "B", count: 100)))
        XCTAssertTrue(text.contains("首条用户指令"))
    }

    /// Verifies permission message contains rich metadata while excluding paths and tool input.
    func testPermissionMessageContainsRichMetadata() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([makeSession(phase: .processing)])
        await coordinator.processSnapshot([makePermissionSession(toolUseId: "tool-private")])

        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("vibe-notch"))
        XCTAssertTrue(text.contains("Bash"))
        XCTAssertTrue(text.contains("等待确认执行"))
        XCTAssertFalse(text.contains("/Users/private/vibe-notch"))
        XCTAssertFalse(text.contains("private command"))
    }

    /// Verifies GUI processes without TTY are labeled as Codex Desktop.
    func testGUIProcessTerminalFormatting() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        let session = SessionState(
            sessionId: "session-gui",
            cwd: "/opt/app/aitools",
            projectName: "aitools",
            pid: 66809,
            tty: nil,
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: "优化钉钉通知",
                lastMessage: "完成",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "修改通知",
                lastUserMessageDate: nil
            )
        )

        await coordinator.processSnapshot([session])
        var waitingSession = session
        waitingSession.phase = .waitingForInput
        await coordinator.processSnapshot([waitingSession])

        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("Codex Desktop (PID: 66809)"))
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





