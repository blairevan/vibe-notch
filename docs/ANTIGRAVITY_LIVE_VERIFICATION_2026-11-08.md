# Antigravity 三端本机部署与真实联调

验收日期：2026-11-08，Asia/Shanghai。

## 部署结果

- 已安装并启动 `/Applications/Vibe Notch.app`，本轮最终验证进程为 PID `49821`。
- 构建配置：Release，arm64，Bundle ID `com.celestial.ClaudeIsland`。
- 沿用原安装的 ad hoc 签名方式；`codesign --verify --deep --strict` 通过。
- 最终可执行文件 SHA-256：`3bf81845506f9d7cf25c5f05706ad878a52bb1e88c297b0d9446649fd3daa904`。
- 原应用与首次部署版本备份在 `build/deploy-backup/20261108-205856/`，未删除原安装副本。
- 全局 `~/.gemini/config/hooks.json` 已安装 `vibe-notch-antigravity` 配置；与部署前比较，其他命名空间的内容保持一致。
- 应用内桥接资源、已安装的桥接脚本与工作区源文件逐字节一致。
- Socket `/tmp/claude-island.sock` 已通过真实连接验证。

## 真实验收矩阵

实际使用已登录客户端发起模型请求，要求仅回复固定标记，不调用工具、不读取或修改文件。
钉钉通过应用的既有机器人配置实发，并在钉钉桌面客户端的 `NotchM5` 会话中读取确认；
不是测试 transport 或仅根据 HTTP 请求成功推断送达。

| 客户端 | 刘海可见状态 | 钉钉实际收信（本地时间） | 点击返回后的系统前台应用 |
| --- | --- | --- | --- |
| agy CLI 1.5.2 | `agy-e2e agy · 任务已完成` | 21:22:55，来源 `agy`，项目 `agy-e2e` | `com.cmuxterm.app`；cmux 显示同一测试会话及最终回复 |
| Antigravity App 2.29.0 | `Unknown Antigravity · 任务已完成` | 21:19:14，来源 `Antigravity` | `com.google.antigravity` |
| Antigravity IDE 2.6.0 | `antigravity-ide-e2e Antigravity IDE · 任务已完成` | 21:20:31，来源 `Antigravity IDE`，项目 `antigravity-ide-e2e` | `com.google.antigravity-ide` |

App 测试使用独立的 Outside of Project 会话，因此没有项目目录，`Unknown` 是该会话的项目标签。
IDE 使用单独的测试窗口与 `/tmp/vibe-notch-e2e-20261108/antigravity-ide-e2e` 目录。
agy 的最终验收轮次在 cmux 的可视终端中交互提交，目录为 `/tmp/vibe-notch-e2e-20261108/agy-e2e`。
GUI 返回按首期设计激活正确应用，不宣称已选择指定聊天或窗口。

本轮还观察到命令行预填启动轮次未形成完整可见事件证据，因此不将该轮次计入通过结论；
表中 agy 的通过结果来自应用就绪后明确提交的真实交互轮次。

## 联调发现并修复的兼容问题

1. **后续才发现工作区**：agy 可先发送空工作区的 `SessionStart`，随后在 `PreInvocation` 中提供正确目录。
   原状态模型只保留首次目录，导致项目长期显示 `Unknown`。现已允许仅在初始目录为空时补齐目录和项目名，
   并通过真实通知的 `agy-e2e` 标签回测。
2. **IDE 共用 App 数据目录**：本机 IDE 的测试会话实际写入 `~/.gemini/antigravity/brain/`，
   后端为 IDE 插件派生的 agy hub。现通过宿主进程链识别 IDE；显式 CLI 来源仍保留 CLI 身份，
   不因其运行在 IDE 终端中而误标。实际刘海、钉钉和返回目标均已回测。
3. **cmux 终端识别**：补充 cmux 的进程名与 Bundle ID，使 agy 返回按钮能够激活实际终端。

临时探针只对带测试标记的请求记录字段名、会话标识、目录与结束标记，不记录提示词、回复和凭证；
探针脚本与临时 Hook 命令均已移除。现有 cmux Hooks 未覆盖。

## 自动化验证与部署命令

新增回归用例先复现对应问题后修复。最终 69 个 Swift 测试、9 个 Python 测试通过。
新增 Swift 文件通过格式及 lint 检查；`git diff --check` 通过。
构建仍包含项目原有的 Swift 并发兼容警告，本轮没有将警告视为已清理。

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
xcrun swift-format format -i --configuration '{"indentation":{"spaces":4}}' ClaudeIslandTests/AntigravityIntegrationTests.swift
xcrun swift-format lint --strict --configuration '{"indentation":{"spaces":4}}' ClaudeIsland/Models/AntigravitySession.swift ClaudeIsland/Services/Hooks/AntigravityHookInstaller.swift ClaudeIsland/Services/Window/SessionFocusService.swift ClaudeIslandTests/AntigravityIntegrationTests.swift
xcodebuild test -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme ClaudeIsland -configuration Release -destination 'platform=macOS' -derivedDataPath build/antigravity-deploy CODE_SIGNING_ALLOWED=NO
codesign --force --deep --sign - 'build/antigravity-deploy/Build/Products/Release/Vibe Notch.app'
codesign --verify --deep --strict '/Applications/Vibe Notch.app'
git diff --check
```

三次点击后，分别通过 `/usr/bin/lsappinfo front` 取得前台进程，再调用
`/usr/bin/lsappinfo info -only bundleID <ASN>` 核实 Bundle ID。
应用日志在三个最终验收轮次分别记录 `PreInvocation`、`Stop` 和 `DingTalk HTTP SUCCESS`；
实际收信与来源标签以钉钉客户端的可见消息进一步确认。

## 验证边界与清理

- 本轮真实验收覆盖正常完成、项目标签、来源识别、实际收信和返回应用；
  取消、异常、后台任务和显式子代理过滤由自动化测试覆盖，未逐个进行真实模型故障注入。
- 不将 CLI 打印模式、远程运行、启动预填首轮或指定聊天深链路列为已验收功能。
- 测试 CLI 进程与其后台更新子进程已停止，Vibe Notch 保持运行。
- 测试目录、模型会话与验收记录保留供复查；没有关闭用户原有的工作会话。
- 本轮没有 Git 提交、推送或远程部署。
