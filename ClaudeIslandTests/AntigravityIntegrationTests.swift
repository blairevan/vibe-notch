import Foundation
import XCTest

@testable import Vibe_Notch

/// Regression coverage for notification-only Antigravity integration.
@MainActor
final class AntigravityIntegrationTests: XCTestCase {
    /// The user's cmux terminal is a valid focus destination for agy.
    func testAgyCanFindCmuxTerminalAncestor() {
        let tree: [Int: Vibe_Notch.ProcessInfo] = [
            300: Vibe_Notch.ProcessInfo(
                pid: 300, ppid: 200, command: "/usr/local/bin/agy", tty: "ttys001"),
            200: Vibe_Notch.ProcessInfo(pid: 200, ppid: 100, command: "/bin/zsh", tty: "ttys001"),
            100: Vibe_Notch.ProcessInfo(
                pid: 100, ppid: 1, command: "/Applications/cmux.app/Contents/MacOS/cmux", tty: nil),
        ]
        XCTAssertEqual(ProcessTreeBuilder.shared.findTerminalPid(forProcess: 300, tree: tree), 100)
    }

    /// SessionStart can precede workspace discovery in the real agy client.
    func testWorkspaceDiscoveredAfterSessionStartUpdatesProject() async throws {
        let id = "antigravity-cli:integration-completion"
        await SessionStore.shared.process(
            .hookReceived(try decodeEvent(event: "SessionStart", id: id, cwd: "")))
        await SessionStore.shared.process(
            .hookReceived(try decodeEvent(event: "PreInvocation", id: id, cwd: "/workspace/demo")))
        let value = await SessionStore.shared.session(for: id)
        let session = try XCTUnwrap(value)
        XCTAssertEqual(session.cwd, "/workspace/demo")
        XCTAssertEqual(session.projectName, "demo")
        await SessionStore.shared.process(.sessionEnded(sessionId: id))
    }

    /// agy inside the Antigravity IDE terminal must resolve that IDE as its terminal host.
    func testAgyCanFindAntigravityIDETerminalAncestor() {
        let tree: [Int: Vibe_Notch.ProcessInfo] = [
            300: Vibe_Notch.ProcessInfo(
                pid: 300, ppid: 200, command: "/usr/local/bin/agy", tty: "ttys001"),
            200: Vibe_Notch.ProcessInfo(pid: 200, ppid: 100, command: "/bin/zsh", tty: "ttys001"),
            100: Vibe_Notch.ProcessInfo(
                pid: 100, ppid: 1,
                command: "/Applications/Antigravity IDE.app/Contents/MacOS/Electron", tty: nil),
        ]
        XCTAssertEqual(ProcessTreeBuilder.shared.findTerminalPid(forProcess: 300, tree: tree), 100)
    }

    /// GUI focus selects the correct installed product, while CLI never launches a GUI client.
    func testFocusRoutingKeepsAllThreeClientsSeparate() async {
        for (source, expected) in [
            ("antigravity", "com.google.antigravity"),
            ("antigravity-ide", "com.google.antigravity-ide"),
            ("antigravity-cli", ""),
        ] {
            let session = SessionState(
                sessionId: "focus", cwd: "/workspace/demo",
                conversationInfo: ConversationInfo(clientName: source)
            )
            var activated: [String] = []
            let result = await SessionFocusService.focus(
                session,
                activateApplication: {
                    activated.append($0)
                    return true
                })
            XCTAssertEqual(activated, expected.isEmpty ? [] : [expected])
            XCTAssertEqual(result, !expected.isEmpty)
        }
    }

    /// Installation and removal preserve unrelated configuration on disk.
    func testInstallerWritesOwnedFilesWithoutReplacingOtherHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config/hooks.json")
        try Data(#"{"cmux":{"Stop":[]}}"#.utf8).write(to: config)
        try AntigravityHookInstaller.install(
            in: root, bridgeData: Data("# fixture".utf8), pythonPath: "/usr/bin/python3")
        let installed = try Data(contentsOf: config)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: installed)
        XCTAssertNotNil(decoded["cmux"])
        XCTAssertNotNil(decoded["vibe-notch-antigravity"])
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: root.appendingPathComponent("config/vibe-notch/antigravity_bridge.py").path)
        )
        try Data("invalid json".utf8).write(to: config)
        XCTAssertThrowsError(
            try AntigravityHookInstaller.install(
                in: root, bridgeData: Data(), pythonPath: "/usr/bin/python3"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "invalid json")
    }

    /// A reused upstream execution number must not suppress a genuinely new user turn.
    func testEachTurnHasIndependentCompletionIdentity() throws {
        var state = AntigravitySession(conversationId: "integration-completion")
        let start = try XCTUnwrap(decodeEvent(event: "PreInvocation").antigravity)
        let stop = try XCTUnwrap(decodeEvent(reason: "NO_TOOL_CALL").antigravity)
        state.apply(event: "PreInvocation", metadata: start)
        state.apply(event: "PreInvocation", metadata: start)
        state.apply(event: "Stop", metadata: stop)
        let first = state.completionID
        state.apply(event: "Stop", metadata: stop)
        XCTAssertEqual(state.completionID, first)
        state.apply(event: "PreInvocation", metadata: start)
        state.apply(event: "Stop", metadata: stop)
        XCTAssertNotEqual(state.completionID, first)
        XCTAssertEqual(state.generation, 2)
    }

    /// Error events notify, while nested, cancelled, and uncertain terminal states do not.
    func testTerminalNotificationPolicyForEverySource() async throws {
        for source in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            for (reason, subagent, expected) in [
                ("ERROR", false, 1), ("USER_CANCELED", false, 0), ("FUTURE", false, 0),
                ("NO_TOOL_CALL", true, 0),
            ] {
                let id = "\(source):integration-completion"
                var messages: [DingTalkMessage] = []
                let coordinator = DingTalkNotificationCoordinator(
                    credentialStore: AntigravityTestCredentials(), isEnabled: { true },
                    send: { message, _ in messages.append(message) }
                )
                await coordinator.processSnapshot([])
                await SessionStore.shared.process(
                    .hookReceived(
                        try decodeEvent(
                            event: "PreInvocation", id: id, source: source, subagent: subagent)))
                let before = await SessionStore.shared.session(for: id)
                await coordinator.processSnapshot([try XCTUnwrap(before)])
                await SessionStore.shared.process(
                    .hookReceived(
                        try decodeEvent(reason: reason, id: id, source: source, subagent: subagent))
                )
                let after = await SessionStore.shared.session(for: id)
                await coordinator.processSnapshot([try XCTUnwrap(after)])
                XCTAssertEqual(messages.count, expected, "\(source): \(reason), nested=\(subagent)")
                if expected == 1 {
                    XCTAssertEqual(messages.first?.title, "Vibe Notch - Task Error")
                }
                await SessionStore.shared.process(.sessionEnded(sessionId: id))
            }
        }
    }

    /// Installer merges only its namespace, preserving cmux and disabled state.
    func testConfigurationMergePreservesOtherHooksAndIsIdempotent() throws {
        let existing = Data(
            #"{"cmux":{"Stop":[]},"vibe-notch-antigravity":{"enabled":false}}"#.utf8)
        let first = try AntigravityHookInstaller.configuration(
            merging: existing, bridgePath: "/tmp/path with spaces/bridge.py",
            pythonPath: "/usr/bin/python3"
        )
        let second = try AntigravityHookInstaller.configuration(
            merging: first, bridgePath: "/tmp/path with spaces/bridge.py",
            pythonPath: "/usr/bin/python3"
        )
        XCTAssertEqual(first, second)
        let config = try JSONDecoder().decode([String: AnyCodable].self, from: first)
        XCTAssertNotNil(config["cmux"])
        let own = try XCTUnwrap(config["vibe-notch-antigravity"]?.value as? [String: Any])
        XCTAssertEqual(own["enabled"] as? Bool, false)
        XCTAssertThrowsError(
            try AntigravityHookInstaller.configuration(
                merging: Data("broken".utf8), bridgePath: "/tmp/bridge.py",
                pythonPath: "/usr/bin/python3"
            ))
    }

    /// Fully idle, explicit terminal events are the only source of completion.
    func testBackgroundCancellationAndUnknownStopsNeverBecomeSuccess() throws {
        var state = AntigravitySession(conversationId: "integration-completion")
        let start = try XCTUnwrap(decodeEvent(event: "PreInvocation").antigravity)
        state.apply(event: "PreInvocation", metadata: start)
        state.apply(
            event: "Stop",
            metadata: try XCTUnwrap(
                decodeEvent(reason: "NO_TOOL_CALL", fullyIdle: false).antigravity))
        XCTAssertTrue(state.isActive)
        XCTAssertNil(state.completionID)
        state.apply(
            event: "Stop", metadata: try XCTUnwrap(decodeEvent(reason: "USER_CANCELED").antigravity)
        )
        XCTAssertEqual(state.outcome, .cancelled)
        state.apply(event: "PreInvocation", metadata: start)
        state.apply(
            event: "Stop", metadata: try XCTUnwrap(decodeEvent(reason: "FUTURE_REASON").antigravity)
        )
        XCTAssertEqual(state.outcome, .stopped)
    }

    /// Installed uppercase enums and documented lowercase enums share classification.
    func testTerminationReasonCompatibility() throws {
        for reason in ["NO_TOOL_CALL", "model_stop", "EXECUTOR_TERMINATION_REASON_NO_TOOL_CALL"] {
            XCTAssertEqual(try decodeEvent(reason: reason).antigravity?.outcome, .completed)
        }
        for reason in ["ERROR", "max_steps_exceeded", "MAX_TOKEN_BUDGET_EXCEEDED"] {
            XCTAssertEqual(try decodeEvent(reason: reason).antigravity?.outcome, .failed)
        }
    }

    /// Antigravity events must not launch Claude's transcript parsing pipeline.
    func testAntigravityDoesNotSyncClaudeFiles() throws {
        let event = try decodeEvent(reason: "NO_TOOL_CALL")
        XCTAssertFalse(event.shouldSyncFile)
    }

    /// Event-only completions notify without exposing a user prompt or reply.
    func testCompletionWithoutConversationContentNotifiesOnce() async throws {
        let id = "antigravity-cli:integration-completion"
        let store = SessionStore.shared
        var messages: [DingTalkMessage] = []
        let coordinator = DingTalkNotificationCoordinator(
            credentialStore: AntigravityTestCredentials(), isEnabled: { true },
            send: { message, _ in messages.append(message) }
        )
        await coordinator.processSnapshot([])
        await store.process(.hookReceived(try decodeEvent(event: "PreInvocation", id: id)))
        let runningValue = await store.session(for: id)
        let running = try XCTUnwrap(runningValue)
        await coordinator.processSnapshot([running])
        let stop = try decodeEvent(reason: "NO_TOOL_CALL", id: id)
        await store.process(.hookReceived(stop))
        let completedValue = await store.session(for: id)
        let completed = try XCTUnwrap(completedValue)
        await coordinator.processSnapshot([completed])
        await store.process(.hookReceived(stop))
        let duplicateValue = await store.session(for: id)
        let duplicate = try XCTUnwrap(duplicateValue)
        await coordinator.processSnapshot([duplicate])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.text.contains("agy") == true)
        XCTAssertNil(completed.conversationInfo.lastMessage)
        await store.process(.sessionEnded(sessionId: id))
    }

    /// Creates the wire payload independently of the production bridge.
    private func decodeEvent(
        event: String = "Stop", reason: String = "",
        id: String = "antigravity-cli:integration-completion",
        fullyIdle: Bool = true, source: String = "antigravity-cli", subagent: Bool = false,
        cwd: String = "/workspace/demo"
    ) throws -> HookEvent {
        let payload: [String: Any] = [
            "session_id": id, "cwd": cwd, "client": source,
            "event": event, "status": event == "Stop" ? "waiting_for_input" : "processing",
            "antigravity": [
                "conversationId": "integration-completion", "executionNum": 1,
                "invocationNum": 0, "fullyIdle": fullyIdle,
                "terminationReason": reason, "hasError": false, "isSubagent": subagent,
            ],
        ]
        return try JSONDecoder().decode(
            HookEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

/// Supplies local fixture credentials to the recording transport only.
@MainActor
private final class AntigravityTestCredentials: DingTalkCredentialStoring {
    /// Returns a placeholder consumed only by the injected recording transport.
    func load() throws -> DingTalkCredentials {
        DingTalkCredentials(token: "fixture", signingSecret: "")
    }
    /// Leaves persistent credentials untouched.
    func save(_ credentials: DingTalkCredentials) throws {}
    /// Leaves persistent credentials untouched.
    func clear() throws {}
}
