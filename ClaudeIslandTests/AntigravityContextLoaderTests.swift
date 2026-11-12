import Foundation
import SQLite3
import XCTest

@testable import Vibe_Notch

/// Verifies that terminal notifications read only the matching current turn.
@MainActor
final class AntigravityContextLoaderTests: XCTestCase {
    /// A sparse Stop must retain this turn's request rather than reuse the first turn.
    func testStopWithoutPromptPreservesCurrentRequestAndResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SessionStore(notificationContextLoader: fixture.loader)
        var metadata = fixture.metadata()
        metadata.initialNumSteps = 1
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"FIRST RESULT"}
            """)
        await store.process(.hookReceived(hook("PreInvocation", metadata: metadata)))
        await store.process(.hookReceived(hook("Stop", metadata: metadata)))
        metadata.lastUserInput = "CURRENT REQUEST"
        metadata.initialNumSteps = 3
        await store.process(.hookReceived(hook("PreInvocation", metadata: metadata)))
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"FIRST RESULT"}
            {"type":"USER_INPUT","step_index":2,"content":"CURRENT REQUEST"}
            {"type":"PLANNER_RESPONSE","step_index":3,"content":"CURRENT RESULT"}
            """)
        metadata.lastUserInput = nil
        await store.process(.hookReceived(hook("Stop", metadata: metadata)))
        let completed = await store.session(for: "antigravity-cli:one")
        XCTAssertEqual(completed?.conversationInfo.firstUserMessage, "same")
        XCTAssertEqual(completed?.conversationInfo.lastUserMessage, "CURRENT REQUEST")
        XCTAssertEqual(completed?.conversationInfo.lastMessage, "CURRENT RESULT")
    }

    /// A partially written final row must delay delivery of any preceding intermediate answer.
    func testPartialFinalRowDoesNotPublishIntermediateAnswer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"INTERMEDIATE"}
            {"type":"PLANNER_RESPONSE","step_index":2,"content":
            """)
        let file = fixture.log
        let loader = AntigravityNotificationContextLoader(
            roots: [fixture.root],
            sleep: {
                let text = """
                    {"type":"USER_INPUT","step_index":0,"content":"same"}
                    {"type":"PLANNER_RESPONSE","step_index":1,"content":"INTERMEDIATE"}
                    {"type":"PLANNER_RESPONSE","step_index":2,"content":"FINAL RESULT"}
                    """
                try Data((text + "\n").utf8).write(to: file)
            })
        let content = await loader.load(
            metadata: fixture.metadata(), initialStep: 1, startedAt: .distantPast)
        XCTAssertEqual(content.response, "FINAL RESULT")
    }

    /// Real App/IDE transcripts wrap requests and append runtime metadata.
    func testWrappedUserRequestMatchesPlainHookPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"<USER_REQUEST>\\nsame\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>runtime context</ADDITIONAL_METADATA>"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"WRAPPED ANSWER"}
            """)
        let result = await fixture.loader.load(
            metadata: fixture.metadata(), initialStep: 1, startedAt: .distantPast)
        XCTAssertEqual(result.response, "WRAPPED ANSWER")
        XCTAssertEqual(result.prompt, "same")
    }

    /// A delayed old read and duplicate Stop cannot complete or overwrite a newer turn.
    func testNewTurnWinsOverDelayedOldContent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entered = expectation(description: "reader is waiting for transcript")
        let gate = ContentReadGate(entered: entered)
        let loader = AntigravityNotificationContextLoader(
            roots: [fixture.root], sleep: { await gate.pause() })
        let store = SessionStore(notificationContextLoader: loader)
        var metadata = fixture.metadata()
        metadata.initialNumSteps = 1
        let start = hook("PreInvocation", metadata: metadata)
        let stop = hook("Stop", metadata: metadata)
        await store.process(.hookReceived(start))
        let finishing = Task { await store.process(.hookReceived(stop)) }
        await fulfillment(of: [entered], timeout: 2)
        await store.process(.hookReceived(stop))
        let pending = await store.session(for: "antigravity-cli:one")
        XCTAssertEqual(pending?.phase, .processing)
        metadata.lastUserInput = "NEW REQUEST"
        metadata.initialNumSteps = 3
        await store.process(.hookReceived(hook("PreInvocation", metadata: metadata)))
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"OLD RESULT"}
            """)
        await gate.release()
        await finishing.value
        let current = await store.session(for: "antigravity-cli:one")
        XCTAssertEqual(current?.phase, .processing)
        XCTAssertEqual(current?.conversationInfo.lastUserMessage, "NEW REQUEST")
        XCTAssertNil(current?.conversationInfo.lastMessage)
    }

    /// Build a lifecycle event without accessing an installed client's configuration.
    private func hook(_ name: String, metadata: AntigravityHookMetadata) -> HookEvent {
        HookEvent(
            sessionId: "antigravity-cli:one", cwd: "/workspace/demo", event: name,
            status: name == "Stop" ? "waiting_for_input" : "processing", pid: nil, tty: nil,
            tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil, message: nil,
            client: "antigravity-cli", antigravity: metadata)
    }

    /// A repeated prompt must not reuse the previous turn's response.
    func testCurrentTurnSelectionAndReadOnlyTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"OLD"}
            {"type":"USER_INPUT","step_index":2,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":3,"content":"CURRENT"}
            """)
        try fixture.title("Renamed title")
        let database = fixture.root.appendingPathComponent("conversation_summaries.db")
        let before = try Data(contentsOf: database)
        let content = await fixture.loader.load(
            metadata: fixture.metadata(), initialStep: 3, startedAt: .distantPast)
        XCTAssertEqual(content.title, "Renamed title")
        XCTAssertEqual(content.response, "CURRENT")
        XCTAssertEqual(try Data(contentsOf: database), before)
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"OLD"}
            """)
        let stale = await fixture.loader.load(
            metadata: fixture.metadata(), initialStep: 3, startedAt: .distantPast)
        XCTAssertNil(stale.response)
    }

    /// A partial final row is retried; tool-call thinking text is never a final answer.
    func testDelayedFinalRowAndToolStep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"same"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"INTERNAL","tool_calls":[{}]}
            {"type":"PLANNER_RESPONSE","step_index":2,"content":
            """)
        let file = fixture.log
        let loader = AntigravityNotificationContextLoader(
            roots: [fixture.root],
            sleep: {
                let text =
                    "{\"type\":\"USER_INPUT\",\"step_index\":0,\"content\":\"same\"}\n{\"type\":\"PLANNER_RESPONSE\",\"step_index\":2,\"content\":\"READY\"}\n"
                try Data(text.utf8).write(to: file)
            })
        let content = await loader.load(
            metadata: fixture.metadata(), initialStep: 1, startedAt: .distantPast)
        XCTAssertEqual(content.response, "READY")
    }

    /// Neither a different conversation nor a symlink can redirect a transcript read.
    func testRejectsWrongConversationAndSymlinkEscape() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("{\"type\":\"PLANNER_RESPONSE\",\"step_index\":1,\"content\":\"HIDDEN\"}")
        var metadata = fixture.metadata()
        metadata.transcriptPath = fixture.root.appendingPathComponent("other.jsonl").path
        let wrong = await fixture.loader.load(
            metadata: metadata, initialStep: 0, startedAt: .distantPast)
        XCTAssertNil(wrong.response)
        let other = fixture.root.appendingPathComponent("outside.jsonl")
        try Data("HIDDEN".utf8).write(to: other)
        try FileManager.default.removeItem(at: fixture.log)
        try FileManager.default.createSymbolicLink(at: fixture.log, withDestinationURL: other)
        let escaped = await fixture.loader.load(
            metadata: fixture.metadata(), initialStep: 0, startedAt: .distantPast)
        XCTAssertNil(escaped.response)
    }

    /// Missing logs return the current hook prompt/error without inventing a reply.
    func testMissingLogPreservesPromptAndError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var metadata = fixture.metadata()
        metadata.error = "Current failure"
        let content = await fixture.loader.load(
            metadata: metadata, initialStep: 1, startedAt: .distantPast)
        XCTAssertEqual(content.prompt, "same")
        XCTAssertEqual(content.error, "Current failure")
        XCTAssertNil(content.response)
    }

    /// Upstream subagent rows in conversation_summaries.db must suppress completion and question notifications even when the hook omits isSubagent.
    func testDatabaseLineageSuppressesSubagentWhenHookOmitsFlag() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSummaryRow(
            title: "",
            parentConversationId: "parent-session-uuid",
            nestingDepth: 1,
            agentName: "browser"
        )
        try fixture.write(
            """
            {"type":"SYSTEM_MESSAGE","step_index":0,"content":"<SYSTEM_MESSAGE>\\nTask brief\\n</SYSTEM_MESSAGE>"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"Batch 1 verified"}
            """)
        let store = SessionStore(notificationContextLoader: fixture.loader)
        var messages: [DingTalkMessage] = []
        let coordinator = DingTalkNotificationCoordinator(
            credentialStore: LoaderTestCredentials(),
            isEnabled: { true },
            send: { message, _ in messages.append(message) }
        )
        await coordinator.processSnapshot([])

        var metadata = fixture.metadata()
        metadata.lastUserInput = ""
        metadata.initialNumSteps = 0
        await store.process(.hookReceived(hook("PreInvocation", metadata: metadata)))
        if let active = await store.session(for: "antigravity-cli:one") {
            await coordinator.processSnapshot([active])
        }
        await store.process(.hookReceived(hook("Stop", metadata: metadata)))
        let finishedRaw = await store.session(for: "antigravity-cli:one")
        let finished = try XCTUnwrap(finishedRaw)
        XCTAssertEqual(finished.antigravity?.isSubagent, true)
        XCTAssertTrue(finished.conversationInfo.isSubagent)
        await coordinator.processSnapshot([finished])
        XCTAssertTrue(messages.isEmpty)

        let questionContext = await fixture.loader.loadQuestionMetadata(metadata)
        XCTAssertTrue(questionContext.isSubagent)
    }

    /// Before SQLite flushes, a step-0 inter-agent SYSTEM_MESSAGE must also mark the session as a subagent.
    func testStepZeroInterAgentMessageSuppressesSubagentWithoutDatabase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"SYSTEM_MESSAGE","step_index":0,"content":"The following is a <SYSTEM_MESSAGE>\\n\\n<SYSTEM_MESSAGE>\\n[Message] timestamp=2026-11-12T05:54:39Z sender=parent-session-uuid priority=HIGH content=Inspect browser\\n</SYSTEM_MESSAGE>"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"Completed browser check"}
            """)
        var metadata = fixture.metadata()
        metadata.lastUserInput = nil
        let content = await fixture.loader.load(
            metadata: metadata, initialStep: 0, startedAt: .distantPast)
        XCTAssertTrue(content.isSubagent)
    }

    /// Reactive wakeup Stop payloads with an empty lastUserInput string must preserve the cached user prompt and extract the final answer.
    func testEmptyStringStopPromptPreservesUserRequestOnReactiveWakeup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.title("Local Browser Access Request")
        let store = SessionStore(notificationContextLoader: fixture.loader)
        var startMeta = fixture.metadata()
        startMeta.lastUserInput = "<USER_REQUEST>\n已登录，请执行浏览器校验\n</USER_REQUEST>"
        startMeta.initialNumSteps = 1
        await store.process(.hookReceived(hook("PreInvocation", metadata: startMeta)))

        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"<USER_REQUEST>\\n已登录，请执行浏览器校验\\n</USER_REQUEST>"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"","tool_calls":[{}]}
            {"type":"SYSTEM_MESSAGE","step_index":2,"content":"<SYSTEM_MESSAGE>\\n[Message] sender=subagent content=Done\\n</SYSTEM_MESSAGE>"}
            {"type":"PLANNER_RESPONSE","step_index":3,"content":"第一批实测已完成"}
            """)
        var stopMeta = startMeta
        stopMeta.lastUserInput = "   "
        await store.process(.hookReceived(hook("Stop", metadata: stopMeta)))
        let completedRaw = await store.session(for: "antigravity-cli:one")
        let completed = try XCTUnwrap(completedRaw)
        XCTAssertEqual(completed.conversationInfo.summary, "Local Browser Access Request")
        XCTAssertEqual(completed.conversationInfo.lastUserMessage, "已登录，请执行浏览器校验")
        XCTAssertEqual(completed.conversationInfo.lastMessage, "第一批实测已完成")
    }

    /// When Vibe Notch restarts mid-turn and receives Stop without a cached prompt, the loader anchors to the latest USER_INPUT in the transcript.
    func testMissingPromptRecoversLatestUserInputFromTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            """
            {"type":"USER_INPUT","step_index":0,"content":"第一轮问题"}
            {"type":"PLANNER_RESPONSE","step_index":1,"content":"第一轮回答"}
            {"type":"USER_INPUT","step_index":2,"content":"<USER_REQUEST>\\n第二轮问题\\n</USER_REQUEST>"}
            {"type":"PLANNER_RESPONSE","step_index":3,"content":"第二轮最终回答"}
            """)
        var metadata = fixture.metadata()
        metadata.lastUserInput = nil
        let content = await fixture.loader.load(
            metadata: metadata, initialStep: 3, startedAt: .distantPast)
        XCTAssertEqual(content.prompt, "第二轮问题")
        XCTAssertEqual(content.response, "第二轮最终回答")
    }
}

/// Synthetic credentials used to verify subagent suppression end-to-end.
@MainActor
private final class LoaderTestCredentials: DingTalkCredentialStoring {
    /// Return a deterministic test token without touching Keychain or disk.
    func load() throws -> DingTalkCredentials {
        DingTalkCredentials(token: "fixture", signingSecret: "")
    }
    /// Ignore saves in tests.
    func save(_ credentials: DingTalkCredentials) throws {}
    /// Ignore clears in tests.
    func clear() throws {}
}

/// Coordinates a real suspended read without polling or wall-clock sleeps.
private actor ContentReadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    /// Record the expectation used to observe entry into the retry interval.
    init(entered: XCTestExpectation) { self.entered = entered }

    /// Suspend until the test starts a newer turn and releases the reader.
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    /// Resume the one owned content read.
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Owns an isolated allowed data root and synthetic upstream trajectory.
@MainActor
private struct Fixture {
    let root: URL
    let log: URL
    let loader: AntigravityNotificationContextLoader

    /// Create the exact on-disk layout accepted for one conversation.
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        log = root.appendingPathComponent("brain/one/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        loader = AntigravityNotificationContextLoader(roots: [root], sleep: {})
    }

    /// Construct a decoded hook payload independently of the production bridge.
    func metadata() -> AntigravityHookMetadata {
        var metadata = AntigravityHookMetadata(
            conversationId: "one", executionNum: 1, invocationNum: nil, fullyIdle: true,
            terminationReason: "NO_TOOL_CALL", hasError: false, isSubagent: false)
        metadata.transcriptPath = log.path
        metadata.lastUserInput = "same"
        return metadata
    }

    /// Write a synthetic trajectory, preserving newline-delimited JSON framing.
    func write(_ text: String) throws { try Data((text + "\n").utf8).write(to: log) }

    /// Create the upstream summary schema and one renamed title.
    func title(_ title: String) throws {
        var db: OpaquePointer?
        guard
            sqlite3_open(root.appendingPathComponent("conversation_summaries.db").path, &db)
                == SQLITE_OK
        else {
            throw NSError(domain: "FixtureSQLite", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql =
            "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT); INSERT INTO conversation_summaries VALUES ('one','\(title.replacingOccurrences(of: "'", with: "''"))');"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureSQLite", code: 2)
        }
    }

    /// Create the full upstream summary schema including subagent lineage columns.
    func writeSummaryRow(
        title: String,
        parentConversationId: String,
        nestingDepth: Int,
        agentName: String
    ) throws {
        var db: OpaquePointer?
        guard
            sqlite3_open(root.appendingPathComponent("conversation_summaries.db").path, &db)
                == SQLITE_OK
        else {
            throw NSError(domain: "FixtureSQLite", code: 3)
        }
        defer { sqlite3_close(db) }
        let esc = { (s: String) in s.replacingOccurrences(of: "'", with: "''") }
        let sql = """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                parent_conversation_id TEXT NOT NULL DEFAULT '',
                nesting_depth INTEGER NOT NULL DEFAULT 0,
                agent_name TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO conversation_summaries VALUES (
                'one',
                '\(esc(title))',
                '\(esc(parentConversationId))',
                \(nestingDepth),
                '\(esc(agentName))'
            );
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureSQLite", code: 4)
        }
    }

    /// Remove only the temporary files owned by this fixture.
    func remove() { try? FileManager.default.removeItem(at: root) }
}
