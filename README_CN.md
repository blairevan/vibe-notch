**English | [中文](README_CN.md)**

<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Vibe Notch（原 Claude Island）</h3>
  <p align="center">
    一款 macOS 菜单栏应用，为 Claude Code CLI 会话带来灵动岛风格的通知体验。
    <br />
    <br />
    <a href="https://github.com/farouqaldori/vibe-notch/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/farouqaldori/vibe-notch?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/farouqaldori/vibe-notch/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

> **🟢 持续维护中**
>
> 2025 年 12 月发布 v1.2 后休息了 4 个月。v1.3（2026 年 4 月）正在处理积压的贡献者 PR 和 Bug 报告，并恢复定期更新节奏。感谢耐心等待。

## 功能特性

- **刘海 UI** — 从 MacBook 刘海区域动画展开的通知覆盖层
- **实时会话监控** — 同时追踪多个 Claude Code 会话
- **Antigravity 通知与跳转** — 支持 agy CLI、Antigravity App 和 Antigravity IDE 的任务状态、完成/异常通知及返回来源应用
- **权限审批** — 直接在刘海区域批准或拒绝工具执行
- **聊天历史** — 支持 Markdown 渲染的完整对话历史
- **自动配置** — 首次启动时自动安装 Hooks

## 环境要求

- macOS 15.6+
- Claude Code CLI

## 安装

下载最新版本：

👉 **[Releases 页面](https://github.com/hunterlarcuad/vibe-notch/releases)**

### 一键安装

1. 下载 `Vibe-Notch-*-arm64-with-installer.zip`
2. 解压后双击 `install.command`
3. 完成！

### 手动安装

```bash
# 解压 zip
unzip Vibe-Notch-*.zip
# 复制到应用程序
cp -R "Vibe Notch.app" /Applications/
# 移除安全隔离
xattr -dr com.apple.quarantine "/Applications/Vibe Notch.app"
```

### 从源码构建

```bash
git clone https://github.com/hunterlarcuad/vibe-notch.git
cd vibe-notch
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## 使用说明

详细使用说明请参考：[docs/MAC_USER_GUIDE_CN.md](docs/MAC_USER_GUIDE_CN.md)

## 隐私说明

本 fork 版本已**完全移除** Mixpanel 数据上报，不采集任何使用数据。

## 许可证

Apache 2.0
