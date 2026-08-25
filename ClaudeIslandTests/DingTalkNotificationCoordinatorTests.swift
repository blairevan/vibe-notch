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

    /// Verifies session initialization (idle to waitingForInput) does not trigger task completion.
    func testIdleToWaitingForInputDoesNotNotify() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        await coordinator.processSnapshot([])
        await coordinator.processSnapshot([makeSession(phase: .idle)])
        await coordinator.processSnapshot([makeSession(phase: .waitingForInput)])

        XCTAssertTrue(recorder.messages.isEmpty)
    }

    /// Verifies empty session without user prompts does not trigger notification even on processing to waitingForInput.
    func testEmptySessionWithoutUserPromptDoesNotNotify() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        let emptySessionProcessing = SessionState(
            sessionId: "empty-session",
            cwd: "/",
            projectName: "/",
            phase: .processing,
            conversationInfo: ConversationInfo()
        )
        var emptySessionWaiting = emptySessionProcessing
        emptySessionWaiting.phase = .waitingForInput

        await coordinator.processSnapshot([])
        await coordinator.processSnapshot([emptySessionProcessing])
        await coordinator.processSnapshot([emptySessionWaiting])

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
        XCTAssertTrue(text.contains("等待权限审批"))
        XCTAssertFalse(text.contains("/Users/private/vibe-notch"))
        XCTAssertTrue(text.contains("private command"))
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

    /// Verifies modern Codex rollout parsing with item_completed UserMessage and AgentMessage.
    func testModernCodexRolloutMessageParsing() async {
        let jsonl = [
            "{\"type\":\"session_meta\",\"payload\":{\"cli_version\":\"0.149.0-alpha.4\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"UserMessage\",\"content\":[{\"type\":\"text\",\"text\":\"<in-app-browser-context>tab 1</in-app-browser-context>\\n\\n## My request:\\n执行单元测试并验证结果\"}]}}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"AgentMessage\",\"content\":[{\"type\":\"Text\",\"text\":\"全部 26 个测试用例已通过！\"}]}}}"
        ].joined(separator: "\n")
        
        let info = await ConversationParser.shared.parseContentForTesting(jsonl, isCodex: true)
        XCTAssertEqual(info.lastUserMessage, "执行单元测试并验证结果")
        XCTAssertEqual(info.firstUserMessage, "执行单元测试并验证结果")
        XCTAssertEqual(info.lastMessage, "全部 26 个测试用例已通过！")
        XCTAssertEqual(info.lastMessageRole, "assistant")
    }

    func testLegacyCodexRolloutMessageParsing() async {
        let jsonl = """
        {"type":"session_meta","payload":{"cli_version":"0.148.0-alpha.15"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"审查当前修改的代码"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"审查完成，无异常。"}]}}
        """
        
        let info = await ConversationParser.shared.parseContentForTesting(jsonl, isCodex: true)
        XCTAssertEqual(info.lastUserMessage, "审查当前修改的代码")
        XCTAssertEqual(info.firstUserMessage, "审查当前修改的代码")
        XCTAssertEqual(info.lastMessage, "审查完成，无异常。")
    }


        /// Verifies DSH (DeepSeek Harness) transcript parsing with session/title, user prompt, and assistant message.
    func testDshSessionTranscriptParsing() async {
        let lines = [
            #"{"type":"session","version":0,"id":"session-ce2c609f-1e64-4391-ae57-0a1db6d1bfb2","createdAt":1787319666416,"cwd":"/opt/app/aitools"}"#,
            #"{"type":"session/title","seq":18,"time":1787319721739,"data":{"title":"http://127.0.0.1:3080/ 网页版","source":{"kind":"fallback"}}}"#,
            #"{"type":"user/message","seq":14,"time":1787319721737,"data":{"content":[{"type":"text","text":"The approval policy changed to never"}],"source":{"kind":"plugin","plugin":"user-approval"},"role":"user"}}"#,
            #"{"type":"user/message","seq":15,"time":1787319721738,"data":{"content":[{"type":"text","text":"网页版和 desktop 版不能并存吗？"}],"source":{"kind":"user"},"role":"user"}}"#,
            #"{"type":"session/title","seq":27,"time":1787319723295,"data":{"title":"网页版和desktop版能否并存","source":{"kind":"provider"}}}"#,
            #"{"type":"turn/start","seq":10,"time":1787319721723,"data":{"turn":1}}"#,
            #"{"type":"tool/call","seq":120,"time":1787319722000,"data":{"tool":"read","callId":"call-1","input":{"file_path":"config.json"}}}"#,
            #"{"type":"tool/result","seq":121,"time":1787319722100,"data":{"callId":"call-1","result":"ok"}}"#,
            #"{"type":"assistant/message","seq":3319,"time":1787321622693,"data":{"turn":1,"step":2,"message":{"role":"assistant","content":[{"type":"reasoning","text":"Analyzing port conflict..."},{"type":"text","text":"答案是：不能并存。两个实例存在账本文件锁冲突。"}],"source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-pro"}},"usage":{"inputTokens":1299,"outputTokens":387,"cacheReadTokens":49152}}}"#,
            #"{"type":"turn/end","seq":3321,"time":1787321622694,"data":{"turn":1,"reason":{"kind":"completed"}}}"#
        ]
        let jsonl = lines.joined(separator: "\n")

        let info = await ConversationParser.shared.parseContentForTesting(jsonl, isDsh: true)
        XCTAssertEqual(info.clientName, "dsh")
        XCTAssertEqual(info.summary, "网页版和desktop版能否并存")
        XCTAssertEqual(info.firstUserMessage, "网页版和 desktop 版不能并存吗？")
        XCTAssertEqual(info.lastUserMessage, "网页版和 desktop 版不能并存吗？")
        XCTAssertEqual(info.lastMessage, "答案是：不能并存。两个实例存在账本文件锁冲突。")
        XCTAssertEqual(info.lastMessageRole, "assistant")
        XCTAssertEqual(info.usage.inputTokens, 1299)
        XCTAssertEqual(info.usage.outputTokens, 387)
    }

    /// Verifies DSH task completed notification output formatted for DingTalk.
    func testDshTaskCompletedDingTalkNotification() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        let session = SessionState(
            sessionId: "session-ce2c609f-1e64-4391-ae57-0a1db6d1bfb2",
            cwd: "/opt/app/aitools",
            projectName: "aitools",
            pid: 38777,
            tty: nil,
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: "网页版和desktop版能否并存",
                lastMessage: "答案是：不能并存。两个实例存在账本文件锁冲突。",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "网页版和 desktop 版不能并存吗？",
                lastUserMessageDate: nil,
                lastUserMessage: "网页版和 desktop 版不能并存吗？",
                clientName: "dsh"
            )
        )

        await coordinator.processSnapshot([session])
        var waitingSession = session
        waitingSession.phase = .waitingForInput
        await coordinator.processSnapshot([waitingSession])

        XCTAssertEqual(recorder.messages.count, 1)
        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("### 🚀 Vibe Notch - 任务已完成"))
        XCTAssertTrue(text.contains(#"- **项目**：`aitools`"#))
        XCTAssertTrue(text.contains("- **主题**：网页版和desktop版能否并存"))
        XCTAssertTrue(text.contains("- **状态**：✅ 执行完成 (等待输入)"))
        XCTAssertTrue(text.contains("网页版和 desktop 版不能并存吗？"))
        XCTAssertTrue(text.contains("答案是：不能并存。两个实例存在账本文件锁冲突。"))
        XCTAssertTrue(text.contains("- **终端**：DSH"))
    }

    /// Verifies DSH permission request notification output.
    func testDshPermissionRequestDingTalkNotification() async {
        let recorder = MessageRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        var session = SessionState(
            sessionId: "session-ce2c609f-1e64-4391-ae57-0a1db6d1bfb2",
            cwd: "/opt/app/aitools",
            projectName: "aitools",
            pid: 38777,
            tty: nil,
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: "配置修复",
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: "修复配置",
                lastUserMessageDate: nil,
                clientName: "dsh"
            )
        )

        await coordinator.processSnapshot([session])
        session.phase = .waitingForApproval(PermissionContext(
            toolUseId: "call-edit-1",
            toolName: "edit",
            toolInput: ["reason": AnyCodable("escalate sandbox to danger-full-access: Install dependencies")],
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        await coordinator.processSnapshot([session])

        XCTAssertEqual(recorder.messages.count, 1)
        let text = recorder.messages.first?.text ?? ""
        XCTAssertTrue(text.contains("### ⚠️ Vibe Notch - 需要权限审批"))
        XCTAssertTrue(text.contains(#"- **项目**：`aitools`"#))
        XCTAssertTrue(text.contains(#"- **工具**：`edit`"#))
        XCTAssertTrue(text.contains("escalate sandbox to danger-full-access: Install dependencies"))
        XCTAssertTrue(text.contains("- **状态**：⏳ 等待权限审批"))
        XCTAssertTrue(text.contains("- **终端**：DSH"))
    }

    /// Verifies system reminder and skill instruction blocks are stripped from user prompt.
    func testDshSystemReminderStripping() async {
        let lines = [
            #"{"type":"session","version":0,"id":"session-123","createdAt":1787319666416,"cwd":"/opt/app/aitools"}"#,
            #"{"type":"user/message","seq":1,"data":{"content":[{"type":"text","text":"<system-reminder>\nAvailable skills...\n</system-reminder>\n\n## My request:\n帮我分析项目结构"}],"source":{"kind":"user"},"role":"user"}}"#
        ]
        let jsonl = lines.joined(separator: "\n")

        let info = await ConversationParser.shared.parseContentForTesting(jsonl, isDsh: true)
        XCTAssertEqual(info.lastUserMessage, "帮我分析项目结构")
        XCTAssertEqual(info.firstUserMessage, "帮我分析项目结构")
    }


    /// Tests live file parsing from disk if ~/.dsh session exists
    func testLiveDshSessionFileParsing() async {
        let sid = "session-4b2822c6-744a-4423-867b-75444f71bde2"
        let info = await ConversationParser.shared.parse(sessionId: sid, cwd: "/opt/app/aitools")
        if info.clientName == "dsh" {
            XCTAssertEqual(info.clientName, "dsh")
            XCTAssertNotNil(info.summary)
            XCTAssertNotNil(info.lastMessage)
        }
    }

    
    /// Verifies HookInstaller creates and registers the DSH plugin if ~/.dsh exists.
    func testHookInstallerDshPlugin() {
        HookInstaller.installDshPluginIfNeeded()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        if fm.fileExists(atPath: home + "/.dsh") {
            let pkgPath = home + "/.dsh/plugins/dsh-vibe-notch/package.json"
            let indexPath = home + "/.dsh/plugins/dsh-vibe-notch/lib/index.js"
            XCTAssertTrue(fm.fileExists(atPath: pkgPath))
            XCTAssertTrue(fm.fileExists(atPath: indexPath))

            let profilePath = home + "/.dsh/profiles/web/package.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let deps = json["dependencies"] as? [String: Any] ?? [:]
                let dsh = json["dsh"] as? [String: Any] ?? [:]
                let profile = dsh["profile"] as? [String: Any] ?? [:]
                let bundles = profile["bundles"] as? [String] ?? []
                XCTAssertNotNil(deps["dsh-vibe-notch"])
                XCTAssertTrue(bundles.contains("dsh-vibe-notch"))
            }
        }
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
            phase: phase,
            conversationInfo: ConversationInfo(
                summary: "任务测试",
                lastMessage: "测试完成",
                lastMessageRole: "assistant",
                firstUserMessage: "测试指令",
                lastUserMessage: "测试指令"
            )
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




