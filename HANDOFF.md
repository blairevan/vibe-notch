# HANDOFF.md

> 当前任务交接文档。每次修改请追加内容并更新修订记录，不要完全覆盖。

---

## 1. 当前任务

**分支**: `main`

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
2. **代码交付**: 已按照 Conventional Commits 规范提交并推送到远端 `main` 分支；后续仅需进行更多真实长程场景验证。

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

---

## 2.3 2026-08-23 DSH (DeepSeek Harness) 消息通知对接

### 变更明细

| 日期 | 模块 / 文件 | 改动内容 | 状态 |
| :--- | :--- | :--- | :--- |
| 2026-08-23 | `ConversationParser.swift` | 新增 `findDshSessionFile`、`readSessionFileContent` (支持 `zstd` 解压) 以及 `parseDshContent`，解析 `~/.dsh/sessions/` 会话。 | ✅ |
| 2026-08-23 | `DingTalkNotificationCoordinator.swift` | 适配 DSH 客户端终端标识与会话主题提取（优先使用 `session/title` LLM 标题）。 | ✅ |
| 2026-08-23 | `HookInstaller.swift` | 新增 `installDshPluginIfNeeded`，自动分发 `dsh-vibe-notch` 插件并注册到 DSH profile。 | ✅ |
| 2026-08-23 | `ClaudeIsland/Resources/dsh-vibe-notch/` | 提供 DSH Cordis 插件，监听 `session/created`、`turn/start`、`tool/call`、`tool/result`、`approval/asked`、`turn/end` 并桥接至 Unix Socket。 | ✅ |
| 2026-08-23 | `DingTalkNotificationCoordinatorTests.swift` | 新增 DSH 会话解析、任务完成与权限审批钉钉通知、`<system-reminder>` 清洗、真实文件加载等单元测试。 | ✅ |

### 验证结果

- **单元测试**: 执行 `xcodebuild test -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，全量 31 个测试用例全部通过（0 failure）。
- **真实数据验证**: 对接 `~/.dsh/sessions/` 下真实 `session.jsonl.zstd` 会话记录，成功解析标题、Prompt 与执行结果。

### 2.4 2026-08-23 DSH 通知连通性故障彻底修复与根因总结

1. **Cordis 事件 Carrier Scope 隔离**:
   - DSH 内部的 `session/*` 事件带有 carrier 作用域过滤。普通 `ctx.on` 在未指定 `{ global: true }` 时会被 filter 拦截，插件虽然被加载但收不到事件流。已通过显式 `{ global: true }` 解决。
2. **macOS Foundation Process 管道死锁 (Pipe Buffer Deadlock)**:
   - DSH 会话解压数据量大（含全量 skills 与 system-prompt，通常 >64KB）。在 `ConversationParser.swift` 中，若先 `process.waitUntilExit()` 再 `readDataToEndOfFile()`，会导致子进程阻塞在满溢的管道缓冲区，父进程死等子进程退出，引发永久死锁。
   - 修复：先 drain 读取管道数据流，再 wait 进程退出，彻底根除死锁。
3. **后台常驻服务与 UI 视图生命周期解耦**:
   - Socket 监听 (`HookSocketServer`) 之前绑定在 SwiftUI `NotchView.onAppear`，无物理刘海或 Accessory 启动时视图可能不触发 appear，导致 Socket 事件被无声丢弃。
   - 修复：在 `ClaudeSessionMonitor` 引入全局单例，由 `AppDelegate.applicationDidFinishLaunching` 统一启动常驻后台服务。
4. **DSH 凭证与代码语法合规**:
   - `~/.dsh/.credentials.yaml` 规范化为扁平键值对映射，修复 `dsh-credentials-local` 启动拦截。

---

## 2.5 2026-08-27 上下文压缩误触发完成通知修复

### 根因

Codex Desktop 在自动上下文压缩时会产生 `PreCompact -> compacting -> processing -> waitingForInput` 的恢复时序。原有协调器只根据 `processing -> waitingForInput` 判断任务完成，导致压缩前的中间助手回复被误认为最终结果并发送钉钉通知。

### 修复与验证

- `DingTalkNotificationCoordinator.swift`：在进入 `compacting` 时记录会话结果指纹（最新用户消息、最新助手消息及角色）；压缩恢复后的等待状态若仍是同一条旧回复则抑制通知，若结果已更新则正常通知。
- `DingTalkNotificationCoordinatorTests.swift`：新增回归测试，覆盖压缩中间状态不通知、最终结果变化后正常通知。
- 全量单元测试：35 个测试通过，0 failure。
- Release 构建通过，并已部署到 `/Applications/Vibe Notch.app` 后重启验证。
- 测试使用独立的 SwiftPM checkout/cache；系统原有 Sparkle checkout 存在损坏对象，未修改项目依赖清单。


---

## 2.7 2026-08-29 零配置自启自检系统与 Diagnostic Doctor 面板实现

### 变更明细

| 日期 | 模块 / 文件 | 改动内容 | 状态 |
| :--- | :--- | :--- | :--- |
| 2026-08-29 | HookInstaller.swift & codex_notify_bridge.py | 增加 Codex config.toml 的 notify 回调自动注入与 codex_notify_bridge.py 自动分发，实现 Codex Desktop 真正零配置即装即用。 | ✅ |
| 2026-08-29 | DingTalkCredentialStore.swift & AppDelegate.swift | 新增 syncEnabledState() 自愈逻辑：检测到本地存在有效 dingtalk.json 时，应用启动自动同步激活 dingTalkEnabled 开关，避免无声漏发。 | ✅ |
| 2026-08-29 | DiagnosticDoctor.swift & DoctorRow.swift | 实现 Vibe Notch 一键体检系统（Doctor）：全景检测 Socket、Claude Hooks、Codex Bridge、DSH 插件、DingTalk 凭证并支持一键 Auto-Fix 与 Ping 测试。 | ✅ |
| 2026-08-29 | DiagnosticDoctorTests.swift & DingTalkCredentialStoreTests.swift | 增加 Doctor 健康检查与凭据开关自愈机制的完整单元测试套件。 | ✅ |

## 6. 修订记录

| 修订时间 | 修订人 | 修订小结 |
| :--- | :--- | :--- |
| 2026-08-22 23:15:00 | Assistant | 初始化 HANDOFF.md，记录 Codex 升级导致钉钉通知字段异常的排查链路与修复。 |
| 2026-08-23 01:20:00 | Assistant | 完成 Vibe Notch 对接 DSH (DeepSeek Harness) 消息通知的全链路开发与测试验证。 |
| 2026-08-23 08:15:00 | Assistant | 彻底排查并修复 DSH 与 Codex 双端通知未达问题（消除了 Pipe 死锁、Cordis 事件隔离并解耦后台生命周期）。 |
| 2026-08-27 16:02:00 | Assistant | 修复上下文压缩恢复阶段误发完成通知，新增结果指纹判定与回归测试；全量 35 测试通过，Release 构建通过并完成本地部署。 |

---

## 2.6 2026-08-29 Codex 启动自检自动安装 Hook 与 Mac mini 部署

### 变更明细

| 日期 | 模块 / 文件 | 改动内容 | 状态 |
| :--- | :--- | :--- | :--- |
| 2026-08-29 | `HookInstaller.swift` | 新增 `installCodexHooksIfNeeded`，启动时自动检测 `~/.codex` 并分发 `~/.codex/hooks/claude-island-state.py` 与 `hooks.json`。 | ✅ |
| 2026-08-29 | `docs/assets/` | 增加 Mac mini 融合风格应用图标资源 `macmini_vibe_notch_dingtalk.png`。 | ✅ |
| 2026-08-29 | Mac mini 部署与联调 | 完成远程 SSH 局域网同步、钉钉开关自愈、Codex `notify` 原生桥接挂载与真实端到端推送验证。 | ✅ |

| 2026-08-29 01:15:00 | Assistant | 新增 Codex 启动自动安装 Hook 机制，完成 Mac mini 局域网部署与 Codex notify 桥接联调。 |
| 2026-08-29 01:30:00 | Assistant | 完成启动自检全覆盖、凭据开关自愈绑定以及 System Diagnostics Doctor 面板与单测。 |

---

## 2.8 2026-08-29 Workspace & Directories 统一收拢与纯菜单栏图标模式 (Menu Bar Only)

### 变更明细

| 日期 | 模块 / 文件 | 改动内容 | 状态 |
| :--- | :--- | :--- | :--- |
| 2026-08-29 | `WorkspaceDirectoriesRow.swift` | 统一收拢 Claude、Codex、DSH 三大 AI 目录管理，实时展示 Active/Not Found 状态，支持分别自定义选择路径与重置。 | ✅ |
| 2026-08-29 | `StatusBarController.swift` | 新增 macOS 顶部菜单栏 `NSStatusItem` 常驻图标，支持点击切换/展示交互面板。 | ✅ |
| 2026-08-29 | `DisplayModeRow.swift` & `Settings.swift` | 支持「灵动岛模式 (Dynamic Island)」与「纯菜单栏模式 (Menu Bar Only)」自由切换，Mac mini 上可彻底隐藏顶部悬浮胶囊。 | ✅ |
| 2026-08-29 | `NotchView.swift` & `AppDelegate.swift` | 在 Menu Bar Only 模式下隐藏静止刘海胶囊，点击菜单栏图标时平滑展开。 | ✅ |

| 2026-08-29 01:40:00 | Assistant | 完成 Workspace & Directories 统一目录行与纯菜单栏图标模式 (Menu Bar Only) 开发及双机部署。 |
