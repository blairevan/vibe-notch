**English | [中文](MAC_USER_GUIDE_CN.md)**

# Vibe Notch - Mac 使用说明

## 简介

Vibe Notch 是一款 macOS 菜单栏应用，为 Claude Code CLI 会话提供类似 iPhone 灵动岛风格的刘海区域通知界面。启动后常驻菜单栏，无需切换窗口即可监控会话状态、审批工具权限。

---

## 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | macOS 15.6 或更高 |
| 硬件 | MacBook（需有刘海设计） |
| 依赖 | 已安装 [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) |

---

## 安装

### 方式一：下载预编译版本（推荐）

1. 前往 [Releases 页面](https://github.com/hunterlarcuad/vibe-notch/releases)
2. 下载 `Vibe-Notch-*-arm64-with-installer.zip`
3. 解压后双击 `install.command` 一键安装

### 方式二：手动安装

```bash
# 解压 zip
unzip Vibe-Notch-*.zip

# 复制到应用程序目录
cp -R "Vibe Notch.app" /Applications/

# 移除安全隔离
xattr -dr com.apple.quarantine "/Applications/Vibe Notch.app"
```

### 方式三：从源码构建

```bash
# 1. 克隆仓库
git clone https://github.com/hunterlarcuad/vibe-notch.git
cd vibe-notch

# 2. 构建应用
xcodebuild -scheme ClaudeIsland -configuration Release build

# 3. 复制到应用程序目录
cp -R "$(find ~/Library/Developer/Xcode/DerivedData -name 'Vibe Notch.app' -path '*/Release/*' | head -1)" /Applications/

# 4. 移除安全隔离
xattr -dr com.apple.quarantine "/Applications/Vibe Notch.app"
```

### 安装后首次运行

```bash
# 启动应用
open -a "Vibe Notch"
```

---

## 启动与退出

### 启动方式

- **Spotlight**: `Cmd + Space` 搜索 `Vibe Notch` 回车
- **启动台**: 在 Launchpad 中找到并点击
- **终端**: `open -a "Vibe Notch"`
- **开机自启**: 可在「系统设置 → 通用 → 登录项与扩展」中添加

### 应用特征

- 启动后**不显示在 Dock**（LSUIElement 模式）
- 仅在**菜单栏**显示状态图标
- 点击菜单栏图标可打开设置面板

### 退出方式

- 点击菜单栏图标 → 选择「退出」
- 或在活动监视器中强制退出 `Vibe Notch` 进程

---

## 自动配置

首次启动时，应用会自动完成以下配置：

```
~/.claude/hooks/
├── hook.sh          # 主 hook 脚本
└── ...              # 相关配置文件
```

这些 hook 通过 Unix socket 与应用通信，**无需手动配置或修改**。

如需重新安装 hooks，删除上述目录后重启应用即可。

---

## 核心功能

### Antigravity 系列：通知与跳转

支持 `agy` CLI、Antigravity App 和 Antigravity IDE。启动新版 Vibe Notch 后，应用会在
`~/.gemini/config/hooks.json` 合并独立的 `vibe-notch-antigravity` 配置，保留已有的 cmux
等 Hooks；桥接脚本位于 `~/.gemini/config/vibe-notch/antigravity_bridge.py`。已打开的客户端
若未加载新配置，可重新打开会话，并在对应客户端的 Hooks 管理界面确认配置已启用。

- 刘海显示来源、项目及处理中、已完成、异常、取消或停止状态。
- 正常完成与明确异常复用现有钉钉通知开关和凭证；取消、未知原因停止不发送成功通知。
- 仅在 `Stop` 明确报告完全空闲后确认终止，后台任务仍运行时保持处理中。
- 点击返回按钮或应用图标：agy 优先定位原 tmux pane/终端，两个 GUI 产品激活各自应用。
  首期 GUI 跳转到应用层级，不保证选择原聊天或原窗口；定位失败会提示手动切换。
- 钉钉消息与 Codex 使用相同模板：项目、主题、状态、本轮任务、最新结果或异常信息，以及耗时、终端和时间。
  本轮任务超过 300 字保留首尾各 150 字，结果或错误超过 400 字保留首尾各 200 字。
  终止事件后只读取对应会话的标题与日志，不发送工具参数、思考内容或完整聊天历史，也不接管审批。
  日志延迟时短暂重试；读取失败显示明确占位，不使用上一轮回复替代。
- 菜单中的体检功能会检查这组 Hooks；可以在上游 Hooks 设置中禁用该配置，Vibe Notch
  后续启动会保留显式禁用状态。

部分 IDE 版本与 App 共用 `~/.gemini/antigravity` 数据目录，桥接会通过宿主进程链识别 IDE，
而在 IDE 内置终端运行的 agy 仍标记为 CLI。agy 在后续事件才补齐工作目录时，项目标签会自动更新。

兼容边界：若上游漏发最终 `Stop`、缺少 `fullyIdle`，或其他 Hooks 强制续跑，状态可能无法
立即反映最终结果；不会通过静默超时推断成功。子代理过滤依赖上游提供的子代理或父会话标记，
尚未完成三个真实客户端的子代理场景联调。远程运行的 Hooks 不会自动转发到本机 Socket。

开发验证：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
xcodebuild test -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

### 1. 刘海通知

应用启动后，会在 MacBook 刘海区域显示一个紧凑的状态指示器。当 Claude Code 有活动时，通知区域会平滑动画展开，显示当前会话信息。

### 2. 会话监控

| 状态 | 显示 | 说明 |
|------|------|------|
| 空闲 (Idle) | 灰色/静默 | 无活跃的 Claude 会话 |
| 处理中 (Processing) | 动态指示器 | Claude 正在执行操作 |
| 等待审批 (Waiting) | 展开通知区 | 需要用户批准工具执行 |
| 已结束 (Ended) | 自动消失 | 会话已关闭 |

支持**同时监控多个** `claude` 会话，每个会话独立显示状态。

### 3. 权限审批

当 Claude Code 需要执行工具（如写入文件、运行命令等）并需要权限时：

1. 刘海区域**自动展开**，显示工具名称和输入参数
2. 点击 **「批准 (Approve)」** → 工具执行
3. 点击 **「拒绝 (Deny)」** → 跳过该工具

无需切换到终端窗口，直接在刘海区域完成操作。

### 4. 聊天历史

点击通知区域可查看当前会话的完整对话历史：

- 支持 **Markdown 渲染**（代码块、标题、列表等）
- 显示工具调用过程和结果
- 实时滚动更新

### 5. 多会话管理

同时运行多个 `claude` 实例时（不同终端窗口），Vibe Notch 会自动识别并分别监控：

- 每个会话独立显示项目名称
- 点击切换查看不同会话
- 按项目名称排序

---

## 日常使用流程

```
1. 启动 Vibe Notch
      ↓
2. 打开终端，正常运行 claude 命令
      ↓
3. 刘海区域自动显示会话状态
      ↓
4. 需要审批时，刘海展开 → 点击操作
      ↓
5. 完成工作后，退出 Claude 或关闭应用
```

---

## 常见问题

### Q: 应用启动后刘海没有显示？

- 确认使用的是 MacBook 且有刘海设计
- 确认 Claude Code CLI 已安装并在终端中运行过 `claude` 命令
- 检查 `~/.claude/hooks/` 目录下是否有 hook 文件

### Q: 权限审批不生效？

- 确认终端中的 Claude 会话仍在运行（未退出）
- 重启应用后重试

### Q: 应用无法启动，提示安全警告？

```bash
xattr -dr com.apple.quarantine "/Applications/Vibe Notch.app"
open -a "Vibe Notch"
```

### Q: 如何完全卸载？

```bash
# 1. 退出应用
osascript -e 'tell application "Vibe Notch" to quit'

# 2. 删除应用
rm -rf "/Applications/Vibe Notch.app"

# 3. 删除 hooks
rm -rf ~/.claude/hooks/

# 4. 删除配置数据
rm -rf ~/Library/Preferences/com.celestial.ClaudeIsland.plist
```

---

## 隐私说明

本 fork 版本（hunterlarcuad/vibe-notch）已**完全移除**原项目的 Mixpanel 数据分析功能：

- 不采集设备标识符
- 不上报应用使用事件
- 不扫描 Claude Code 会话文件
- 不收集任何版本信息

所有数据处理均在本地完成，无任何网络请求（除 Sparkle 自动更新检查外）。

---

## 项目信息

- **仓库**: https://github.com/hunterlarcuad/vibe-notch
- **上游**: https://github.com/farouqaldori/vibe-notch
- **许可证**: Apache 2.0
