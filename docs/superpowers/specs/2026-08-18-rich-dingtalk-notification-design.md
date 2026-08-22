# Rich DingTalk Notification Design

## Goal

Enhance the content and layout of DingTalk group robot notification messages in Vibe Notch by providing rich task summaries, assistant responses, duration stats, and environment details while preserving safety and avoiding secrets or raw full paths in messages.

## Message Formats

### 1. Task Completed (waitingForInput)

```markdown
### 🚀 Vibe Notch - 任务已完成

**项目与会话**
- **项目**：`<projectName>`
- **主题**：<summary or firstUserMessage or "未命名会话">
- **状态**：等待输入 (Waiting for input)

**最新结果**
> <truncated lastMessage with a 200-character limit, or "已完成当前执行，等待进一步输入。">

**执行详情**
- **耗时**：<formattedDuration> (e.g. "1分45秒" or "35秒")
- **终端**：<tty or "未知终端"> (PID: <pid>)
- **时间**：YYYY-MM-DD HH:mm:ss
```

### 2. Permission Required (waitingForApproval)

```markdown
### ⚠️ Vibe Notch - 需要权限审批

**待审批操作**
- **项目**：`<projectName>`
- **工具**：`<pendingToolName>`
- **状态**：等待确认执行 (Waiting for approval)

**环境与时间**
- **终端**：<tty or "未知终端"> (PID: <pid>)
- **时间**：YYYY-MM-DD HH:mm:ss
```

## Data Extraction Rules

1. **Project Name**: Safe extraction from `session.projectName`.
2. **Subject/Summary**: Prefers thread title from `~/.codex/state_5.sqlite`, falls back to `session.conversationInfo.summary`, `session.conversationInfo.firstUserMessage`, and defaults to `"未命名会话"`.
3. **Latest Result**: Trims whitespace and newlines. If the text exceeds 400 characters, preserves the first 200 characters and the last 200 characters joined by `\n...\n` (or ` ... `), otherwise shows the full message. Renders inside Markdown blockquotes (`> `) for clean formatting.
4. **Execution Duration**: Formatted as human-readable minutes and seconds.
5. **Terminal / Process**: Formatted as `session.tty` (and `session.pid` if present).
6. **Time**: Formatted with standard second-level precision `yyyy-MM-dd HH:mm:ss` in local timezone.

## Security & Privacy Constraints

- Do not expose raw file paths or sensitive parameters (e.g. credentials, tokens, command arguments).
- Keep all unit tests passing with mock / in-memory fixtures.

## Affected Components

- `ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift`
- `ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift`
