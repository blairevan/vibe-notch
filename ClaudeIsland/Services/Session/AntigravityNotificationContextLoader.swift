import Foundation
import SQLite3

/// Content for one terminal notification, separate from lifecycle authority.
nonisolated struct AntigravityNotificationContent: Sendable {
    var title: String?
    var prompt: String?
    var response: String?
    var error: String?
    var isSubagent = false
}

/// Metadata resolved synchronously before emitting an `ask_question` notification.
nonisolated struct AntigravityQuestionContext: Sendable {
    var title: String?
    var prompt: String?
    var isSubagent = false
}

/// Reads only the referenced conversation, with bounded tail reads and retry time.
actor AntigravityNotificationContextLoader {
    static let shared = AntigravityNotificationContextLoader()
    private let roots: [URL]
    private let sleep: @Sendable () async throws -> Void

    /// Accept explicit roots and a retry clock for isolated filesystem tests.
    init(
        roots: [URL]? = nil,
        sleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    ) {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".gemini")
        self.roots =
            roots
            ?? ["antigravity", "antigravity-cli", "antigravity-ide"].map {
                gemini.appendingPathComponent($0)
            }
        self.sleep = sleep
    }

    /// Fetch current-turn content, retrying a delayed transcript for at most three intervals.
    func load(metadata: AntigravityHookMetadata, initialStep: Int?, startedAt: Date) async
        -> AntigravityNotificationContent
    {
        let cleanedPrompt = Self.nonEmpty(metadata.lastUserInput.map(Self.userRequest))
        var result = AntigravityNotificationContent(
            prompt: cleanedPrompt,
            error: metadata.error,
            isSubagent: metadata.isSubagent)
        guard let (file, root) = validatedLocation(metadata) else { return result }
        for attempt in 0..<4 {
            if Task.isCancelled { return result }
            let summary = readSummary(root: root, conversationId: metadata.conversationId)
            result.title = summary.title ?? result.title
            if summary.isSubagent {
                result.isSubagent = true
                return result
            }
            if let head = try? readHead(file), Self.isSubagentTranscript(in: head) {
                result.isSubagent = true
                return result
            }
            if let data = try? readTail(file) {
                let extracted = Self.extractTurn(
                    in: data, prompt: cleanedPrompt, initialStep: initialStep,
                    startedAt: startedAt)
                if let matchedPrompt = extracted.prompt, result.prompt == nil {
                    result.prompt = matchedPrompt
                }
                result.response = extracted.response
            }
            if result.response != nil { return result }
            if attempt < 3 {
                do { try await sleep() } catch { return result }
            }
        }
        return result
    }

    /// Perform a single non-blocking read of the conversation title, prompt, and subagent flag for ask_question notifications.
    func loadQuestionMetadata(_ metadata: AntigravityHookMetadata) -> AntigravityQuestionContext {
        let prompt = Self.nonEmpty(metadata.lastUserInput.map(Self.userRequest))
        guard let (file, root) = validatedLocation(metadata) else {
            return AntigravityQuestionContext(
                title: nil, prompt: prompt, isSubagent: metadata.isSubagent)
        }
        let summary = readSummary(root: root, conversationId: metadata.conversationId)
        var isSubagent = metadata.isSubagent || summary.isSubagent
        if !isSubagent, let head = try? readHead(file) {
            isSubagent = Self.isSubagentTranscript(in: head)
        }
        return AntigravityQuestionContext(
            title: summary.title, prompt: prompt, isSubagent: isSubagent)
    }

    /// Unwrap `<USER_REQUEST>` tags and clean a user prompt string without reading disk.
    nonisolated static func cleanHookPrompt(_ raw: String) -> String {
        userRequest(raw)
    }

    /// Require the exact conversation log under an allowed product root; reject symlink escapes.
    private func validatedLocation(_ metadata: AntigravityHookMetadata) -> (URL, URL)? {
        guard let path = metadata.transcriptPath, path.hasPrefix("/"),
            !metadata.conversationId.isEmpty, !metadata.conversationId.contains("/"),
            metadata.conversationId != ".", metadata.conversationId != ".."
        else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["transcript.jsonl", "transcript_full.jsonl"].contains(file.lastPathComponent) else {
            return nil
        }
        for root in roots {
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            let expected = canonical.appendingPathComponent("brain").appendingPathComponent(
                metadata.conversationId
            )
            .appendingPathComponent(".system_generated/logs").appendingPathComponent(
                file.lastPathComponent)
            if file.path == expected.path { return (file, canonical) }
        }
        return nil
    }

    /// Read at most 64 KiB from the beginning of the transcript to inspect step 0.
    private func readHead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 65_536) ?? Data()
    }

    /// Read at most 2 MiB from the end, discarding an incomplete first row.
    private func readTail(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > 2_097_152 ? end - 2_097_152 : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: Int(end - start)) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 10) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }

    /// Detect transcripts spawned by a parent agent whose step 0 is an inter-agent SYSTEM_MESSAGE.
    private static func isSubagentTranscript(in head: Data) -> Bool {
        guard let firstRow = head.split(separator: 10, maxSplits: 1).first,
            let step = try? JSONDecoder().decode(Step.self, from: Data(firstRow)),
            step.stepIndex == 0,
            step.type == "SYSTEM_MESSAGE",
            let content = step.content
        else {
            return false
        }
        return content.contains("[Message]") && content.contains("sender=")
    }

    /// Select the final non-tool assistant step and resolved user prompt for this invocation.
    private static func extractTurn(
        in data: Data, prompt: String?, initialStep: Int?, startedAt: Date
    ) -> (prompt: String?, response: String?) {
        let decoder = JSONDecoder()
        var matchedUser = false
        var resolvedPrompt = prompt
        var answer: String?
        let rows = data.split(separator: 10)
        for (index, row) in rows.enumerated() {
            guard let step = try? decoder.decode(Step.self, from: Data(row)) else {
                // An unfinished final row may supersede an earlier visible response.
                if index == rows.count - 1 { return (resolvedPrompt, nil) }
                continue
            }
            if step.type == "USER_INPUT" {
                let candidate = nonEmpty(step.content.map(userRequest))
                if let prompt {
                    matchedUser = candidate == prompt
                } else if let candidate {
                    matchedUser = true
                    resolvedPrompt = candidate
                } else {
                    matchedUser = false
                }
                answer = nil
            }
            guard step.type == "PLANNER_RESPONSE" else { continue }
            answer = nil
            let isCurrent: Bool
            if let initialStep {
                isCurrent = step.stepIndex >= initialStep
            } else if let stamp = step.createdAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
                isCurrent = date.map { $0 >= startedAt } ?? false
            } else {
                isCurrent = false
            }
            if matchedUser, isCurrent, step.toolCalls?.isEmpty != false,
                let content = nonEmpty(step.content)
            {
                answer = content
            }
        }
        return (resolvedPrompt, answer)
    }

    /// Return a trimmed string when non-empty, treating whitespace-only text as nil.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Strip only the upstream request envelope before comparing the prompt to its hook value.
    private static func userRequest(_ value: String) -> String {
        if let start = value.range(of: "<USER_REQUEST>"),
            let end = value.range(of: "</USER_REQUEST>", range: start.upperBound..<value.endIndex)
        {
            return ConversationParser.cleanUserPrompt(
                String(value[start.upperBound..<end.lowerBound]))
        }
        return ConversationParser.cleanUserPrompt(value)
    }

    /// Query title and optional subagent lineage columns using a read-only SQLite connection.
    private func readSummary(root: URL, conversationId: String) -> (
        title: String?, isSubagent: Bool
    ) {
        let file = root.appendingPathComponent("conversation_summaries.db")
        guard file.resolvingSymlinksInPath().path == file.path,
            FileManager.default.fileExists(atPath: file.path)
        else { return (nil, false) }
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else {
            if let database { sqlite3_close(database) }
            return (nil, false)
        }
        defer { sqlite3_close(database) }

        let extendedSQL =
            "SELECT title, parent_conversation_id, nesting_depth, agent_name FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, extendedSQL, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            return conversationId.withCString { id in
                guard sqlite3_bind_text(statement, 1, id, -1, nil) == SQLITE_OK,
                    sqlite3_step(statement) == SQLITE_ROW
                else { return (nil, false) }
                let title = Self.columnText(statement, index: 0)
                let parentId = Self.columnText(statement, index: 1)
                let depth = sqlite3_column_int(statement, 2)
                let agentName = Self.columnText(statement, index: 3)
                let isSubagent = parentId != nil || depth > 0 || agentName != nil
                return (title, isSubagent)
            }
        }
        if let statement { sqlite3_finalize(statement) }

        var fallbackStatement: OpaquePointer?
        let fallbackSQL =
            "SELECT title FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, fallbackSQL, -1, &fallbackStatement, nil) == SQLITE_OK
        else { return (nil, false) }
        defer { sqlite3_finalize(fallbackStatement) }
        return conversationId.withCString { id in
            guard sqlite3_bind_text(fallbackStatement, 1, id, -1, nil) == SQLITE_OK,
                sqlite3_step(fallbackStatement) == SQLITE_ROW
            else { return (nil, false) }
            return (Self.columnText(fallbackStatement, index: 0), false)
        }
    }

    /// Read a nullable UTF-8 text column and normalize whitespace-only strings to nil.
    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return nonEmpty(String(cString: raw))
    }

    /// Decode only visible message fields, ignoring thinking, arguments, and tool results.
    private struct Step: Decodable {
        let type: String
        let stepIndex: Int
        let content: String?
        let createdAt: String?
        let toolCalls: [ToolCall]?
        enum CodingKeys: String, CodingKey {
            case type, content
            case stepIndex = "step_index"
            case createdAt = "created_at"
            case toolCalls = "tool_calls"
        }
    }

    /// Deliberately ignore the contents of tool calls.
    private struct ToolCall: Decodable {}
}
