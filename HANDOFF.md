# HANDOFF.md

> 当前任务交接文档。每次修改请追加内容并更新修订记录，不要完全覆盖。

---

## 1. 当前任务

**分支**: `agent/dingtalk-notifications`

**目标**: 修复 Vibe Notch 钉钉通知中「主题」与「本轮任务」字段缺失或错位的问题，全面适配 Codex Desktop 在 2026-08-21 升级（`0.148.0-alpha.21` 及以上）后引入的 JSONL 会话日志事件重构与 SQLite 数据库字段分离机制。

**涉及核心文件**:
- `ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift` — 钉钉通知协调器（会话标题提取、通知内容组装与格式化）
- `ClaudeIsland/Services/Session/ConversationParser.swift` — 会话日志解析器（Codex/Claude 多版本协议适配、用户 Prompt 提取与清洗）
- `ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift` — 单元测试套件

---

## 2. 已完成内容

### 2.1 变更明细

| 日期 | 模块 / 文件 | 改动内容 | 状态 |
| :--- | :--- | :--- | :--- |
| 2026-08-22 | `DingTalkNotificationCoordinator.swift` | `fetchCodexThreadTitle` SQL 改为 `SELECT COALESCE(NULLIF(name, ''), title) FROM threads WHERE id = ...`，优先获取用户重命名后的会话名称。 | ✅ |
| 2026-08-22 | `ConversationParser.swift` | 新增 `extractCodexUserMessage` 方法，同时兼容新版 `item_completed` (`UserMessage`)、`response_item` (`role == "user"`) 以及旧版 `user_message` 事件。 | ✅ |
| 2026-08-22 | `ConversationParser.swift` | 新增 `cleanUserPrompt` 方法，自动提取 `## My request:` 后的核心用户指令，并过滤系统注入的环境块（如 `<in-app-browser-context>`、`<recommended_plugins>` 等）。 | ✅ |
| 2026-08-22 | `DingTalkNotificationCoordinatorTests.swift` | 增加新旧两套 Codex Rollout 格式的单元测试，涵盖 Prompt 提取与环境上下文清洗逻辑。 | ✅ |
| 2026-08-22 | 运行时构建与部署 | 重新构建 Debug 版本并安全同步至 `/Applications/Vibe Notch.app`，重启应用进程（PID: 59998）。 | ✅ |

### 2.2 验证结果

- **单元测试**: 执行 `xcodebuild test -scheme ClaudeIsland -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，全量 26 个测试用例全部通过（0 failure）。
- **真实数据验证**:
  - 真实多轮会话（以「长程任务 Demo」为例）查询成功返回用户重命名后的会话名称 `长程任务 Demo`，而非初始提问。
  - 会话日志中最新一轮 Prompt 成功解析为 `默认仅 1 小时有效，如果任务在1小时没有跑完，会怎样？`，而非 `未提供任务描述`。

---

## 3. 卡住的问题

- 暂无阻塞问题。所有核心问题均已定位并通过测试用例与本地运行环境双重验证。

---

## 4. 下一步计划

1. **多场景长程监控**: 在更多真实场景（如包含多轮工具调用、Subagent 派发、长时间长程任务）中验证通知的稳定性与排版表现。
2. **代码提交确认**: 待用户确认后，按照 Conventional Commits 规范提交代码并推送到远端 `agent/dingtalk-notifications` 分支。

---

## 5. 踩过的坑与经验总结

1. **排查问题必须以时序证据为准，严禁无数据推测**:
   - 当遇到“之前是好的，忽然不行了”的情况时，第一时间必须对比历史会话文件（如 `~/.codex/sessions/YYYY/MM/DD/*.jsonl`）与数据库的 schema 演变，通过时序切片定位断代版本（本次即为 8月20日 `0.148.0-alpha.15` 到 8月21日 `0.148.0-alpha.21` 的变更）。
2. **Codex 会话重命名字段分离**:
   - 在新版 Codex Desktop 数据库（`~/.codex/state_5.sqlite`）中，初始提问被固定存储在 `threads.title`，用户重命名后的名称存储在 `threads.name`。若只查询 `title`，重命名的会话永远只能读到最初创建时的标题。
3. **Codex Rollout JSONL 事件类型演进**:
   - 旧版格式使用 `{"type":"event_msg","payload":{"type":"user_message","message":"..."}}`；
   - 新版格式改为 `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"..."}]}}}`。
   - 解析器必须保持前向与后向兼容性。
4. **Prompt 系统环境噪音清理**:
   - Codex 客户端会在首轮或带环境的交互中注入大量 XML 标记（如 `<recommended_plugins>`、`<INSTRUCTIONS>`、`<in-app-browser-context>` 等）。若不进行针对性清洗或提取 `## My request:` 后的正文，钉钉通知将被系统提示词淹没。
5. **macOS 应用安全替换**:
   - 替换正在运行的 `.app` 产物时，避免使用 `rm -rf`（受安全策略限制且易残留），优先使用 `ditto` 原子同步并重启进程。

---

## 6. 修订记录

| 修订时间 | 修订人 | 修订小结 |
| :--- | :--- | :--- |
| 2026-08-22 23:15:00 | Assistant | 初始化 HANDOFF.md，记录 Codex 升级导致钉钉通知字段异常的排查链路、代码改动、单元测试、踩坑经验与后续计划。 |


