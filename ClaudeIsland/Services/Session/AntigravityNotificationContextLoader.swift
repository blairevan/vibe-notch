import Foundation
import SQLite3

/// Content for one terminal notification, separate from lifecycle authority.
nonisolated struct AntigravityNotificationContent: Sendable {
    var title: String?
    var prompt: String?
    var response: String?
    var error: String?
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
        var result = AntigravityNotificationContent(
            prompt: metadata.lastUserInput.map { Self.userRequest($0) },
            error: metadata.error)
        guard let (file, root) = validatedLocation(metadata) else { return result }
        for attempt in 0..<4 {
            if Task.isCancelled { return result }
            result.title =
                readTitle(root: root, conversationId: metadata.conversationId) ?? result.title
            if let data = try? readTail(file) {
                result.response = Self.response(
                    in: data, prompt: metadata.lastUserInput, initialStep: initialStep,
                    startedAt: startedAt)
            }
            if result.response != nil { return result }
            if attempt < 3 {
                do { try await sleep() } catch { return result }
            }
        }
        return result
    }

    /// Perform a single non-blocking read of the conversation title and stripped user prompt for ask_question notifications.
    func loadQuestionMetadata(_ metadata: AntigravityHookMetadata) -> (title: String?, prompt: String?) {
        let prompt = metadata.lastUserInput.map { Self.userRequest($0) }
        guard let (_, root) = validatedLocation(metadata) else {
            return (nil, prompt)
        }
        let title = readTitle(root: root, conversationId: metadata.conversationId)
        return (title, prompt)
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

    /// Select the final non-tool assistant step after this invocation's initial trajectory.
    private static func response(in data: Data, prompt: String?, initialStep: Int?, startedAt: Date)
        -> String?
    {
        let decoder = JSONDecoder()
        var matchedUser = false
        var answer: String?
        let rows = data.split(separator: 10)
        for (index, row) in rows.enumerated() {
            guard let step = try? decoder.decode(Step.self, from: Data(row)) else {
                // An unfinished final row may supersede an earlier visible response.
                if index == rows.count - 1 { return nil }
                continue
            }
            if step.type == "USER_INPUT" {
                matchedUser = step.content.map { userRequest($0) } == prompt.map { userRequest($0) }
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
                let content = step.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            {
                answer = content
            }
        }
        return answer
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

    /// Query one title using a bound parameter and a read-only SQLite connection.
    private func readTitle(root: URL, conversationId: String) -> String? {
        let file = root.appendingPathComponent("conversation_summaries.db")
        guard file.resolvingSymlinksInPath().path == file.path,
            FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        let path = file.path
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT title FROM conversation_summaries WHERE conversation_id = ? LIMIT 1", -1,
                &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        return conversationId.withCString { id in
            guard sqlite3_bind_text(statement, 1, id, -1, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0)
            else { return nil }
            let title = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
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
