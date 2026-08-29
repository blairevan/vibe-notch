import Combine
import Foundation
import os.log

/// Observes unified session state and sends privacy-safe DingTalk notifications.
@MainActor
final class DingTalkNotificationCoordinator {
    /// Injectable sender used by production code and unit tests.
    typealias SendHandler = (DingTalkMessage, DingTalkCredentials) async throws -> Void

    private static let logger = Logger(subsystem: "com.claudeisland", category: "DingTalk")

    private let credentialStore: DingTalkCredentialStoring
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let send: SendHandler
    private var subscription: AnyCancellable?
    private var hasSeededSnapshot = false
    private var previousPhases: [String: PhaseMarker] = [:]
   private var notifiedPermissionIds: [String: Set<String>] = [:]
   /// Last known conversation result captured when a session begins compaction.
   private var compactionBaselines: [String: CompletionFingerprint] = [:]
    /// Last notified completion fingerprint for each session, used for deduplication.
    private var lastNotifiedCompletions: [String: CompletionFingerprint] = [:]
   /// Serializes concurrent processSnapshot calls — only one runs at a time, in order.
    private var processingTask: Task<Void, Never>?

    /// Creates a coordinator with injectable state and transport dependencies.
    init(
        credentialStore: DingTalkCredentialStoring? = nil,
        isEnabled: (() -> Bool)? = nil,
        now: (() -> Date)? = nil,
        send: SendHandler? = nil
    ) {
        self.credentialStore = credentialStore ?? DingTalkCredentialStore.shared
        self.isEnabled = isEnabled ?? { AppSettings.dingTalkEnabled }
        self.now = now ?? Date.init

        if let send {
            self.send = send
        } else {
            let client = DingTalkClient()
            self.send = { message, credentials in
                try await client.send(message, credentials: credentials)
            }
        }
    }

    /// Starts observing the central session publisher once.
    func start() {
        guard subscription == nil else { return }
        subscription = SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                // Chain new snapshot onto the previous task to guarantee serial execution.
                // Without this, multiple concurrent Tasks could race on previousPhases.
                let previous = self.processingTask
                self.processingTask = Task { @MainActor in
                    _ = await previous?.value
                    await self.processSnapshot(sessions)
                }
            }
    }

    /// Stops observing and clears transient deduplication state.
    func stop() {
        subscription?.cancel()
        subscription = nil
        processingTask?.cancel()
        processingTask = nil
        hasSeededSnapshot = false
       previousPhases.removeAll()
       notifiedPermissionIds.removeAll()
       compactionBaselines.removeAll()
        lastNotifiedCompletions.removeAll()
   }

    /// Processes one complete session snapshot and sends newly triggered messages.
    func processSnapshot(_ sessions: [SessionState]) async {
        guard hasSeededSnapshot else {
            seedSnapshot(sessions)
            return
        }

        removeStateForMissingSessions(sessions)
        var messages: [DingTalkMessage] = []

       for session in sessions {
           let currentPhase = PhaseMarker(session.phase)
           let previousPhase = previousPhases[session.sessionId]
            let fingerprint = CompletionFingerprint(session: session)

           Self.logger.info("[DingTalk Debug] session=\(session.sessionId.prefix(8), privacy: .public) currentPhase=\(String(describing: currentPhase), privacy: .public) previousPhase=\(String(describing: previousPhase), privacy: .public)")

            let isCompletion: Bool
            switch (previousPhase, currentPhase) {
           case (.processing, .waitingForInput),
                (.compacting, .waitingForInput),
                (.waitingForApproval, .waitingForInput):
               // Compaction recovery can briefly expose the pre-compaction
               // assistant response as a waiting state. It is not a turn end.
               if let baseline = compactionBaselines.removeValue(forKey: session.sessionId),
                   baseline == fingerprint {
                    isCompletion = false
                } else if lastNotifiedCompletions[session.sessionId] == fingerprint {
                    isCompletion = false
                } else {
                    isCompletion = fingerprint.hasUserContent
                }
            default:
                isCompletion = false
            }

           if currentPhase == .compacting {
                compactionBaselines[session.sessionId] = fingerprint
           }

            let logLine = "[\(getpid())] [coordinator] eval session=\(session.sessionId.prefix(8)) cur=\(currentPhase) prev=\(String(describing: previousPhase)) isCompletion=\(isCompletion)\n"
            if let d = logLine.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/vibe-notch-flow.log") {
                fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
            }

           if isCompletion {
                lastNotifiedCompletions[session.sessionId] = fingerprint
               Self.logger.info("[DingTalk Debug] SENDING task completed notification for \(session.sessionId.prefix(8), privacy: .public)")
               messages.append(taskCompletedMessage(for: session))
           }

            if case .waitingForApproval(let toolUseId) = currentPhase {
                var sessionIds = notifiedPermissionIds[session.sessionId] ?? []
                if sessionIds.insert(toolUseId).inserted {
                    messages.append(permissionMessage(for: session))
                }
                notifiedPermissionIds[session.sessionId] = sessionIds
            }

            previousPhases[session.sessionId] = currentPhase
        }

        await sendMessagesIfConfigured(messages)
    }

    /// Seeds current phases and permissions without generating historical messages.
   private func seedSnapshot(_ sessions: [SessionState]) {
       hasSeededSnapshot = true
       for session in sessions {
           let phase = PhaseMarker(session.phase)
           previousPhases[session.sessionId] = phase
           if case .waitingForApproval(let toolUseId) = phase {
               notifiedPermissionIds[session.sessionId] = [toolUseId]
           }
       }
   }

    /// Removes state belonging to sessions no longer present in the snapshot.
    private func removeStateForMissingSessions(_ sessions: [SessionState]) {
        let activeIds = Set(sessions.map(\.sessionId))
       previousPhases = previousPhases.filter { activeIds.contains($0.key) }
       notifiedPermissionIds = notifiedPermissionIds.filter { activeIds.contains($0.key) }
       compactionBaselines = compactionBaselines.filter { activeIds.contains($0.key) }
        lastNotifiedCompletions = lastNotifiedCompletions.filter { activeIds.contains($0.key) }
   }

    /// Sends generated messages when enabled credentials are available.
    private func sendMessagesIfConfigured(_ messages: [DingTalkMessage]) async {
        guard !messages.isEmpty, isEnabled() else { return }
        Self.logger.info("[DingTalk Debug] sendMessagesIfConfigured: \(messages.count) messages, isEnabled=\(self.isEnabled(), privacy: .public)")

        let logLine = "[\(getpid())] [coordinator] sending \(messages.count) DingTalk messages\n"
        if let d = logLine.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/vibe-notch-flow.log") {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
        }

        let credentials: DingTalkCredentials
        do {
            credentials = try credentialStore.load().trimmed
        } catch {
            Self.logger.error("Could not load DingTalk credentials")
            return
        }
        guard !credentials.token.isEmpty else { return }

        for message in messages {
            do {
                try await send(message, credentials)
            } catch {
                Self.logger.error("DingTalk notification failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Creates a task-completed message containing rich and safe session metadata.
    private func taskCompletedMessage(for session: SessionState) -> DingTalkMessage {
        let rawProject = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (rawProject.isEmpty || rawProject == "/") ? "Default" : safeValue(rawProject, fallback: "Default")
        let subject = extractSubject(from: session)
        let prompt = extractLastUserPrompt(from: session)
        let result = extractResult(from: session)
        let duration = formattedDuration(for: session)
        let terminalInfo = extractTerminalInfo(from: session)
        let timeString = formattedTime()

        return DingTalkMessage(
            title: "Vibe Notch - Task Completed",
            text: """
            ### 🚀 Vibe Notch - 任务已完成

            **项目与会话**
            - **项目**：`\(projectName)`
            - **主题**：\(subject)
            - **状态**：✅ 执行完成 (等待输入)

            **本轮任务**
            > \(prompt)

            **最新结果**
            > \(result)

            **执行详情**
            - **耗时**：\(duration)
            - **终端**：\(terminalInfo)
            - **时间**：\(timeString)
            """
        )
    }

    /// Creates a permission message without including tool input or full paths.
    private func permissionMessage(for session: SessionState) -> DingTalkMessage {
        let rawProject = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (rawProject.isEmpty || rawProject == "/") ? "Default" : safeValue(rawProject, fallback: "Default")
        let toolName = safeValue(session.pendingToolName ?? "Unknown", fallback: "Unknown")
        let terminalInfo = extractTerminalInfo(from: session)
        let timeString = formattedTime()

        return DingTalkMessage(
            title: "Vibe Notch - Permission Required",
            text: """
            ### ⚠️ Vibe Notch - 需要权限审批

            **待审批操作**
            - **项目**：`\(projectName)`
            - **工具**：`\(toolName)`\(session.pendingToolInput.map { "\n- **详情**：`" + safeValue($0, fallback: "") + "`" } ?? "")
            - **状态**：⏳ 等待权限审批

            **环境与时间**
            - **终端**：\(terminalInfo)
            - **时间**：\(timeString)
            """
        )
    }

    /// Formats the injected current time in the user's local timezone.
    private func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: now())
    }

    /// Extracts the session subject/summary with fallbacks, checking DSH and Codex SQLite thread title first.
    private func extractSubject(from session: SessionState) -> String {
        if session.conversationInfo.clientName == "dsh" || session.cwd.contains(".dsh") {
            if let summary = session.conversationInfo.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return safeValue(summary, fallback: "未命名会话")
            }
            if let firstUser = session.conversationInfo.firstUserMessage, !firstUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return safeValue(firstUser, fallback: "未命名会话")
            }
            return "未命名会话"
        }

        if let dbTitle = fetchCodexThreadTitle(sessionId: session.sessionId), !dbTitle.isEmpty {
            return safeValue(dbTitle, fallback: "未命名会话")
        }
        if let summary = session.conversationInfo.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return safeValue(summary, fallback: "未命名会话")
        }
        if let firstUser = session.conversationInfo.firstUserMessage, !firstUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return safeValue(firstUser, fallback: "未命名会话")
        }
        return "未命名会话"
    }

    /// Fetches custom thread title from Codex SQLite database (~/.codex/state_5.sqlite)
    private func fetchCodexThreadTitle(sessionId: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = home + "/.codex/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT COALESCE(NULLIF(name, ''), title) FROM threads WHERE id = '\(sessionId)' LIMIT 1;"]
        process.standardOutput = pipe

        do {
            try process.run()
            // Read data before waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Extracts the latest user prompt in the current turn.
    private func extractLastUserPrompt(from session: SessionState) -> String {
        let prompt = session.conversationInfo.lastUserMessage ?? session.conversationInfo.firstUserMessage ?? "未提供任务描述"
        let cleanText = prompt.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
        if cleanText.count <= 300 {
            return formatBlockquote(cleanText)
        } else {
            let head = String(cleanText.prefix(150))
            let tail = String(cleanText.suffix(150))
            return formatBlockquote("\(head)\n...\n\(tail)")
        }
    }

    /// Extracts and formats the latest assistant response, keeping head 200 + tail 200 chars when > 400.
    private func extractResult(from session: SessionState) -> String {
        guard let lastMsg = session.conversationInfo.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastMsg.isEmpty else {
            return "已完成当前执行，等待进一步输入。"
        }
        let cleanText = lastMsg.replacingOccurrences(of: "\r\n", with: "\n")
        if cleanText.count <= 400 {
            return formatBlockquote(cleanText)
        } else {
            let head = String(cleanText.prefix(200))
            let tail = String(cleanText.suffix(200))
            return formatBlockquote("\(head)\n...\n\(tail)")
        }
    }

    /// Wraps multi-line content for blockquote display in Markdown.
    private func formatBlockquote(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .joined(separator: "\n> ")
    }

   /// Formats session active duration based on turnStartTime or conversation timestamp.
   private func formattedDuration(for session: SessionState) -> String {
        let referenceStart = session.conversationInfo.lastUserMessageDate ?? session.turnStartTime ?? session.createdAt
       let interval = max(0, now().timeIntervalSince(referenceStart))
       let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }

    /// Extracts terminal identifier and PID with friendly GUI name.
    private func extractTerminalInfo(from session: SessionState) -> String {
        let clientName = session.conversationInfo.clientName

        // 1. Explicit DSH client types
        if clientName == "dsh-web" {
            if let pid = session.pid {
                return "DSH Web (PID: \(pid))"
            } else {
                return "DSH Web"
            }
        }

        if clientName == "dsh-desktop" {
            if let pid = session.pid {
                return "DSH Desktop (PID: \(pid))"
            } else {
                return "DSH Desktop"
            }
        }

       // 2. DSH general fallback: inspect running process command if available
       if clientName == "dsh" || session.cwd.contains(".dsh") {
           if let pid = session.pid {
               let cmd = fetchProcessCommand(pid: pid) ?? ""
               if cmd.contains("DeepSeek Harness Desktop") {
                   return "DSH Desktop (PID: \(pid))"
               } else if cmd.contains("dsh web") || cmd.contains("dsh-web") {
                   return "DSH Web (PID: \(pid))"
               }
               return "DSH Desktop (PID: \(pid))"
           } else {
               return "DSH Desktop"
           }
       }

        // 3. Explicit Claude Code
        if clientName == "claude" {
            if let tty = session.tty, !tty.isEmpty {
                if let pid = session.pid {
                    return "Claude Code (\(tty), PID: \(pid))"
                }
                return "Claude Code (\(tty))"
            } else if let pid = session.pid {
                return "Claude Code (PID: \(pid))"
            } else {
                return "Claude Code"
            }
        }

        // 4. Interactive terminal TTY (defaults to Claude Code if running in CLI shell)
        if let tty = session.tty, !tty.isEmpty {
            let label = (clientName == "codex") ? "Codex CLI" : "Claude Code"
            if let pid = session.pid {
                return "\(label) (\(tty), PID: \(pid))"
            }
            return "\(label) (\(tty))"
        }

        if clientName == "claude" {
            if let tty = session.tty, !tty.isEmpty {
                if let pid = session.pid {
                    return "Claude Code (\(tty), PID: \(pid))"
                }
                return "Claude Code (\(tty))"
            } else if let pid = session.pid {
                return "Claude Code (PID: \(pid))"
            } else {
                return "Claude Code"
            }
        }

        // GUI process / Desktop app fallback (defaults to Codex Desktop)
        if let pid = session.pid {
            return "Codex Desktop (PID: \(pid))"
        } else {
            return "Codex Desktop"
        }
    }

    /// Helper to fetch command line for a PID to differentiate GUI from CLI web servers
    private func fetchProcessCommand(pid: Int) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Normalizes an external display value and limits its size.
    private func safeValue(_ value: String, fallback: String) -> String {
        var normalized = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip any dangling HTML/XML tags
        normalized = normalized.replacingOccurrences(of: #"</?[a-zA-Z0-9_\-]+(?:\s+[^>]*)?/?>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(100))
    }
}

/// Comparable subset of session phase data used for transition detection.
private enum PhaseMarker: Equatable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval(String)
    case compacting
    case ended

    /// Converts the complete session phase into a comparable marker.
    init(_ phase: SessionPhase) {
        switch phase {
        case .idle:
            self = .idle
        case .processing:
            self = .processing
        case .waitingForInput:
            self = .waitingForInput
        case .waitingForApproval(let context):
            self = .waitingForApproval(context.toolUseId)
        case .compacting:
            self = .compacting
        case .ended:
            self = .ended
        }
    }
}

/// Stable, privacy-safe subset used to compare results across compaction.
private struct CompletionFingerprint: Equatable {
    let lastUserMessage: String?
    let lastMessage: String?
    let lastMessageRole: String?

    /// Captures the conversation fields relevant to a completion notification.
    init(session: SessionState) {
        lastUserMessage = session.conversationInfo.lastUserMessage
        lastMessage = session.conversationInfo.lastMessage
        lastMessageRole = session.conversationInfo.lastMessageRole
    }

    /// Whether the session contains enough conversation content for a notification.
    var hasUserContent: Bool {
        lastUserMessage != nil || lastMessage != nil
    }
}
