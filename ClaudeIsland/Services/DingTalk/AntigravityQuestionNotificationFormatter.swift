import Foundation

/// Pure Markdown formatter for Antigravity `ask_question` waiting-for-user-input DingTalk notifications.
enum AntigravityQuestionNotificationFormatter {
    private static let maxTextLength = 3800

    /// Build a bounded DingTalk Markdown card listing all pending questions and options.
    static func makeMessage(
        projectName: String,
        sourceLabel: String,
        subject: String,
        prompt: String,
        questions: [AntigravityQuestionItem],
        terminalInfo: String,
        timeString: String
    ) -> DingTalkMessage {
        let count = questions.count
        var blocks: [String] = []
        for (index, item) in questions.enumerated() {
            let modeLabel = item.multiSelect ? "可多选" : "单选"
            let cleanTitle = sanitizeInline(item.question, maxLength: 300)
            var lines = ["**Q\(index + 1). \(cleanTitle)**（\(modeLabel)）"]
            for (optIndex, opt) in item.options.enumerated() {
                lines.append("\(optIndex + 1). \(sanitizeInline(opt, maxLength: 220))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        let questionSection = blocks.joined(separator: "\n\n")
        var body = """
        ### ❓ Vibe Notch - 等待确认问题

        **项目与会话**
        - **来源**：\(sourceLabel)
        - **项目**：`\(projectName)`
        - **主题**：\(subject)
        - **状态**：⏳ 等待输入 (共 \(count) 个问题)

        **当前指令**
        > \(prompt)

        **待确认问题**
        \(questionSection)

        **环境与时间**
        - **终端**：\(terminalInfo)
        - **时间**：\(timeString)
        """

        if body.count > maxTextLength {
            body = String(body.prefix(maxTextLength - 24)) + "\n\n…（内容过长已截断）"
        }

        return DingTalkMessage(
            title: "❓ [\(projectName)] 等待输入",
            text: body
        )
    }

    /// Normalize multiline or HTML-tagged snippets into safe single-line Markdown prose.
    private static func sanitizeInline(_ value: String, maxLength: Int) -> String {
        let collapsed = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"</?[a-zA-Z0-9_\-]+(?:\s+[^>]*)?/?>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}
