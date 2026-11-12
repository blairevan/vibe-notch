import Foundation
import XCTest

@testable import Vibe_Notch

/// Checks the Codex-compatible message contract for Antigravity clients.
@MainActor
final class AntigravityNotificationContentTests: XCTestCase {
    /// All three clients must include the same sections and content as Codex.
    func testRichMessageIncludesCurrentTaskAndResultForEveryClient() async throws {
        for source in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            var messages: [DingTalkMessage] = []
            let coordinator = DingTalkNotificationCoordinator(
                credentialStore: ContentTestCredentials(), isEnabled: { true },
                send: { message, _ in messages.append(message) }
            )
            var session = SessionState(
                sessionId: source + ":test", cwd: "/workspace/demo", phase: .processing)
            session.conversationInfo = ConversationInfo(
                summary: "Current title", lastMessage: "Current answer",
                lastMessageRole: "assistant",
                lastUserMessage: "Current request", clientName: source
            )
            var state = AntigravitySession(conversationId: "test")
            let start = try JSONDecoder().decode(
                AntigravityHookMetadata.self,
                from: Data(#"{"conversationId":"test","hasError":false,"isSubagent":false}"#.utf8))
            let stop = try JSONDecoder().decode(
                AntigravityHookMetadata.self,
                from: Data(
                    #"{"conversationId":"test","hasError":false,"isSubagent":false,"fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}"#
                        .utf8))
            state.apply(event: "PreInvocation", metadata: start)
            session.antigravity = state
            await coordinator.processSnapshot([session])
            state.apply(event: "Stop", metadata: stop)
            session.antigravity = state
            session.phase = .waitingForInput
            await coordinator.processSnapshot([session])
            let text = try XCTUnwrap(messages.first?.text)
            for expected in [
                "**项目与会话**", "**主题**", "Current title", "**本轮任务**", "Current request", "**最新结果**",
                "Current answer", "**执行详情**",
            ] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) for \(source)")
            }
        }
    }

    /// Whitespace-only summary and prompt strings must fall back to non-empty fields rather than rendering blank lines.
    func testWhitespaceSummaryAndPromptFallbackCleanly() async throws {
        var messages: [DingTalkMessage] = []
        let coordinator = DingTalkNotificationCoordinator(
            credentialStore: ContentTestCredentials(), isEnabled: { true },
            send: { message, _ in messages.append(message) }
        )

        var state = AntigravitySession(conversationId: "fallback-1")
        let start = try JSONDecoder().decode(
            AntigravityHookMetadata.self,
            from: Data(#"{"conversationId":"fallback-1","hasError":false,"isSubagent":false}"#.utf8)
        )
        let stop = try JSONDecoder().decode(
            AntigravityHookMetadata.self,
            from: Data(
                #"{"conversationId":"fallback-1","hasError":false,"isSubagent":false,"fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}"#
                    .utf8))
        state.apply(event: "PreInvocation", metadata: start)

        var session = SessionState(
            sessionId: "antigravity:fallback-1", cwd: "/workspace/demo", phase: .processing)
        session.conversationInfo = ConversationInfo(
            summary: "   ",
            lastMessage: "已完成排查",
            lastMessageRole: "assistant",
            firstUserMessage: "",
            lastUserMessage: "排查钉钉通知来源",
            clientName: "antigravity"
        )
        session.antigravity = state
        await coordinator.processSnapshot([session])

        state.apply(event: "Stop", metadata: stop)
        session.antigravity = state
        session.phase = .waitingForInput
        await coordinator.processSnapshot([session])

        let firstText = try XCTUnwrap(messages.first?.text)
        XCTAssertTrue(firstText.contains("- **主题**：排查钉钉通知来源"))
        XCTAssertTrue(firstText.contains("> 排查钉钉通知来源"))

        // Also verify empty lastUserMessage falls back to 未提供任务描述 instead of a bare "> "
        messages.removeAll()
        var emptyState = AntigravitySession(conversationId: "fallback-2")
        let start2 = try JSONDecoder().decode(
            AntigravityHookMetadata.self,
            from: Data(#"{"conversationId":"fallback-2","hasError":false,"isSubagent":false}"#.utf8)
        )
        let stop2 = try JSONDecoder().decode(
            AntigravityHookMetadata.self,
            from: Data(
                #"{"conversationId":"fallback-2","hasError":false,"isSubagent":false,"fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}"#
                    .utf8))
        emptyState.apply(event: "PreInvocation", metadata: start2)
        var emptySession = SessionState(
            sessionId: "antigravity:fallback-2", cwd: "/workspace/demo", phase: .processing)
        emptySession.conversationInfo = ConversationInfo(
            summary: "",
            lastMessage: "",
            lastMessageRole: nil,
            firstUserMessage: "   ",
            lastUserMessage: "",
            clientName: "antigravity"
        )
        emptySession.antigravity = emptyState
        await coordinator.processSnapshot([emptySession])

        emptyState.apply(event: "Stop", metadata: stop2)
        emptySession.antigravity = emptyState
        emptySession.phase = .waitingForInput
        await coordinator.processSnapshot([emptySession])

        let secondText = try XCTUnwrap(messages.first?.text)
        XCTAssertTrue(secondText.contains("- **主题**：未命名会话"))
        XCTAssertTrue(secondText.contains("> 未提供任务描述"))
        XCTAssertTrue(secondText.contains("> 未能获取本轮最终回复，请返回原会话查看。"))
    }
}

/// Supplies fixtures only to the in-memory message recorder.
@MainActor
private final class ContentTestCredentials: DingTalkCredentialStoring {
    /// Return synthetic credentials without touching disk.
    func load() throws -> DingTalkCredentials {
        DingTalkCredentials(token: "fixture", signingSecret: "")
    }
    /// Keep the user's credentials unchanged.
    func save(_ credentials: DingTalkCredentials) throws {}
    /// Keep the user's credentials unchanged.
    func clear() throws {}
}
