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
