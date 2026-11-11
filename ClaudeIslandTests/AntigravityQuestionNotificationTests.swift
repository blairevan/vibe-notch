import Foundation
import XCTest

@testable import Vibe_Notch

/// Regression coverage for Antigravity PreToolUse(ask_question) notch phase and DingTalk notifications.
@MainActor
final class AntigravityQuestionNotificationTests: XCTestCase {
    /// Hook configuration must register PreToolUse scoped strictly to ask_question while preserving user entries.
    func testHookInstallerRegistersPreToolUseAskQuestionMatcher() throws {
        let data = try AntigravityHookInstaller.configuration(
            merging: nil,
            bridgePath: "/tmp/vibe/antigravity_bridge.py",
            pythonPath: "/usr/bin/python3"
        )
        let root = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        let own = try XCTUnwrap(root["vibe-notch-antigravity"]?.value as? [String: Any])
        let preToolUse = try XCTUnwrap(own["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(preToolUse.first?["matcher"] as? String, "ask_question")
        let hooks = try XCTUnwrap(preToolUse.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(hooks.first?["command"] as? String)
        XCTAssertTrue(command.contains("PreToolUse"))
    }

    /// Asking questions flips the session to waitingForInput, notifies DingTalk once per stepIdx, and still allows final Stop notification.
    func testAskQuestionNotifiesDingTalkIndependentlyOfTurnCompletion() async throws {
        let id = "antigravity:question-flow"
        let store = SessionStore.shared
        var messages: [DingTalkMessage] = []
        let coordinator = DingTalkNotificationCoordinator(
            credentialStore: QuestionTestCredentials(),
            isEnabled: { true },
            send: { message, _ in messages.append(message) }
        )
        await coordinator.processSnapshot([])

        // 1. Start turn
        await store.process(.hookReceived(try makeEvent(event: "PreInvocation", id: id)))
        let runningRaw = await store.session(for: id)
        let running = try XCTUnwrap(runningRaw)
        XCTAssertEqual(running.phase, .processing)
        await coordinator.processSnapshot([running])
        XCTAssertEqual(messages.count, 0)

        // 2. Emit PreToolUse(ask_question) at stepIdx = 12
        let askEvent = try makeQuestionEvent(id: id, stepIdx: 12)
        await store.process(.hookReceived(askEvent))
        let waitingRaw = await store.session(for: id)
        let waiting = try XCTUnwrap(waitingRaw)
        XCTAssertEqual(waiting.phase, .waitingForInput)
        XCTAssertEqual(waiting.antigravity?.isWaitingForUserInput, true)
        await coordinator.processSnapshot([waiting])
        // Re-evaluating the identical snapshot must not send duplicates
        await coordinator.processSnapshot([waiting])
        XCTAssertEqual(messages.count, 1)
        let questionMsg = try XCTUnwrap(messages.first)
        XCTAssertTrue(questionMsg.title.contains("等待输入"))
        for expected in [
            "### ❓ Vibe Notch - 等待确认问题",
            "toolhub",
            "⏳ 等待输入 (共 2 个问题)",
            "Q1. 统一采用哪种来源命名？",
            "(Recommended) 英文",
            "Q2. 需要同步哪些端？",
            "可多选",
        ] {
            XCTAssertTrue(questionMsg.text.contains(expected), "Missing \(expected) in:\n\(questionMsg.text)")
        }

        // 3. User answers -> PostToolUse resumes processing
        await store.process(.hookReceived(try makeEvent(event: "PostToolUse", id: id)))
        let resumedRaw = await store.session(for: id)
        let resumed = try XCTUnwrap(resumedRaw)
        XCTAssertEqual(resumed.phase, .processing)
        XCTAssertEqual(resumed.antigravity?.isWaitingForUserInput, false)
        await coordinator.processSnapshot([resumed])

        // 4. Turn finishes -> Stop still delivers the standard completion notification
        await store.process(.hookReceived(try makeEvent(event: "Stop", id: id, reason: "NO_TOOL_CALL")))
        let finishedRaw = await store.session(for: id)
        let finished = try XCTUnwrap(finishedRaw)
        XCTAssertEqual(finished.phase, .waitingForInput)
        await coordinator.processSnapshot([finished])
        XCTAssertEqual(messages.count, 2)
        let completionMsg = try XCTUnwrap(messages.last)
        XCTAssertEqual(completionMsg.title, "Vibe Notch - Task Completed")
        XCTAssertTrue(completionMsg.text.contains("- **状态**：✅ 执行完成"))
        XCTAssertFalse(completionMsg.text.contains("等待输入"), "Normal completion must not claim 等待输入:\n\(completionMsg.text)")

        await store.process(.sessionEnded(sessionId: id))
    }

    /// Subagent ask_question events must never spam DingTalk.
    func testSubagentAskQuestionIsSuppressed() async throws {
        let id = "antigravity:subagent-question"
        let store = SessionStore.shared
        var messages: [DingTalkMessage] = []
        let coordinator = DingTalkNotificationCoordinator(
            credentialStore: QuestionTestCredentials(),
            isEnabled: { true },
            send: { message, _ in messages.append(message) }
        )
        await coordinator.processSnapshot([])
        await store.process(.hookReceived(try makeEvent(event: "PreInvocation", id: id, isSubagent: true)))
        await store.process(.hookReceived(try makeQuestionEvent(id: id, stepIdx: 5, isSubagent: true)))
        if let session = await store.session(for: id) {
            await coordinator.processSnapshot([session])
        }
        XCTAssertTrue(messages.isEmpty)
        await store.process(.sessionEnded(sessionId: id))
    }

    private func makeEvent(
        event: String,
        id: String,
        reason: String = "",
        isSubagent: Bool = false
    ) throws -> HookEvent {
        let payload: [String: Any] = [
            "session_id": id,
            "cwd": "/workspace/toolhub",
            "client": "antigravity",
            "event": event,
            "status": event == "Stop" ? "waiting_for_input" : "processing",
            "antigravity": [
                "conversationId": id.replacingOccurrences(of: "antigravity:", with: ""),
                "executionNum": 1,
                "invocationNum": 0,
                "fullyIdle": event == "Stop",
                "terminationReason": reason,
                "hasError": false,
                "isSubagent": isSubagent,
                "lastUserInput": "<USER_REQUEST>对齐两个地方的来源名称</USER_REQUEST>",
            ],
        ]
        return try JSONDecoder().decode(HookEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func makeQuestionEvent(id: String, stepIdx: Int, isSubagent: Bool = false) throws -> HookEvent {
        let payload: [String: Any] = [
            "session_id": id,
            "cwd": "/workspace/toolhub",
            "client": "antigravity",
            "event": "PreToolUse",
            "status": "waiting_for_input",
            "antigravity": [
                "conversationId": id.replacingOccurrences(of: "antigravity:", with: ""),
                "hasError": false,
                "isSubagent": isSubagent,
                "lastUserInput": "<USER_REQUEST>对齐两个地方的来源名称</USER_REQUEST>",
                "questionPrompt": [
                    "stepIdx": stepIdx,
                    "questions": [
                        [
                            "question": "统一采用哪种来源命名？",
                            "options": ["(Recommended) 英文", "中文"],
                            "multiSelect": false,
                        ],
                        [
                            "question": "需要同步哪些端？",
                            "options": ["Web", "Telegram", "DingTalk"],
                            "multiSelect": true,
                        ],
                    ],
                ],
            ],
        ]
        return try JSONDecoder().decode(HookEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

/// Fixture credentials for isolated DingTalk coordinator tests.
@MainActor
private final class QuestionTestCredentials: DingTalkCredentialStoring {
    /// Returns a synthetic token so coordinator builds and emits messages in memory.
    func load() throws -> DingTalkCredentials {
        DingTalkCredentials(token: "fixture", signingSecret: "")
    }
    /// No-op persistence in tests.
    func save(_ credentials: DingTalkCredentials) throws {}
    /// No-op clear in tests.
    func clear() throws {}
}
