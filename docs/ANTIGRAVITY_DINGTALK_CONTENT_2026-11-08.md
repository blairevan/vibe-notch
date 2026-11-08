# Antigravity 钉钉消息与 Codex 对齐

## 行为与范围

agy、Antigravity App、Antigravity IDE 现在复用 Codex 的完成/异常消息模板：

- 项目与会话：项目、主题、状态。
- 本轮任务：当前用户请求，超过 300 字保留首尾各 150 字。
- 最新结果或异常信息：当前轮助手最终回复或错误，超过 400 字保留首尾各 200 字。
- 执行详情：耗时、客户端及可用的 TTY/PID、时间。

这是对第一阶段仅发送状态元数据的扩展。当前用户已明确确认读取本轮请求、最终回复并发送至现有钉钉机器人。
没有增加第三方依赖，也不接管工具审批。完整聊天、思考内容和工具参数不进入通知。

## 数据来源与正确性

1. Hook 传递 `lastUserInput`、`transcriptPath`、`initialNumSteps` 和可用的错误信息。
2. 会话状态仍由 `Stop`、`fullyIdle` 和结束原因决定；读取器不推断任务是否完成。
3. 完成后只读当前产品根目录下该会话的标题数据库和日志，拒绝其他会话路径及符号链接越界。
4. 日志从尾部最多读取 2 MiB，初次读取外最多重试三次，间隔 200ms。
5. 根据当前轮步骤边界和用户请求匹配最终助手回复；缺少步骤边界时使用本轮开始时间作保守校验。
6. 实际 App/IDE 日志把请求包装在 `<USER_REQUEST>` 中并附加运行时元数据，匹配前只提取请求正文。
7. 读取期间的新轮次、归档及重复 Stop 均经过状态校验，旧读取不能覆盖新请求或提前触发通知。
8. 失败时保留当前任务并显示缺失占位，不使用上一轮结果。Socket 解析失败日志不再打印载荷正文。
9. Stop 缺少请求字段时沿用已保存的当前轮请求；末尾 JSON 行未完整落盘时重试，避免提前发送中间回复。

GUI 标题从对应数据根目录的 `conversation_summaries.db` 只读获取；IDE 共用 App 数据目录的情况继续兼容。
没有标题时沿用会话请求的回退，当前轮内容缺失时提示回原会话查看。

## 真实对照结果

测试请求均要求只回复固定标记，不调用工具、不读取文件。以下内容在钉钉桌面客户端实际读取确认：

| 客户端 | 实收时间（Asia/Shanghai） | 本轮任务标记 | 最新结果 | 主题 |
| --- | --- | --- | --- | --- |
| Antigravity App | 22:13:44 | `VIBE_RICH_APP_VERIFIED` | `RESULT_RICH_APP_VERIFIED_OK` | Vibe Notch App Test |
| agy | 22:14:24 | `VIBE_RICH_AGY_VERIFIED` | `RESULT_RICH_AGY_VERIFIED_OK` | System Instruction Test Response |
| Antigravity IDE | 22:14:54 | `VIBE_RICH_IDE_VERIFIED` | `RESULT_RICH_IDE_VERIFIED_OK` | VIBE_NOTCH_IDE_E2E Integration Test |

三条卡片均包含项目与会话、本轮任务、最新结果及执行详情。终端字段分别识别为 Antigravity、agy、Antigravity IDE。
初次 App 对照因未识别请求封装而显示缺失占位；用真实封装结构补充失败回归用例、修复后，三端均取得正确本轮结果。
临时步骤探针已移除，安装脚本与工作区脚本、应用内资源逐字节一致。

验证版已部署到 `/Applications/Vibe Notch.app`，原应用保存在 `build/deploy-backup/rich-dingtalk-before/`。

## 自动化验证

78 个 Swift 测试、9 个 Python 测试通过。覆盖共享模板、当前轮选择、重复提问、请求封装、只读标题、
文件延迟、部分 JSON 行、路径越界、缺失内容、重复结束事件和新轮次覆盖旧读取。
原有 Codex 的结果截断与异常消息测试继续通过。

```bash
xcrun swift-format lint --strict --configuration '{"indentation":{"spaces":4}}' ClaudeIsland/Services/Session/AntigravityNotificationContextLoader.swift ClaudeIslandTests/AntigravityContextLoaderTests.swift ClaudeIslandTests/AntigravityNotificationContentTests.swift
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -q
xcodebuild test -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme ClaudeIsland -configuration Release -destination 'platform=macOS' -derivedDataPath build/antigravity-deploy CODE_SIGNING_ALLOWED=NO
codesign --verify --deep --strict '/Applications/Vibe Notch.app'
git diff --check
```

保留既有边界：GUI 返回为应用层级，CLI 启动预填首轮、远程运行和全部子代理场景不属于本轮新增验收范围。
