# Vibe Notch 对接 DSH (DeepSeek Harness) 消息通知复盘报告

## 1. 任务背景与问题现象

### 1.1 业务目标
为 macOS 灵动岛 / 菜单栏应用 **Vibe Notch** 增加对 **DeepSeek Harness (DSH)** 桌面端任务通知的支持。在 DSH 会话执行完成（进入等待输入状态）或触发工具审批时，将结构化的任务卡片（包括项目、智能标题、用户指令、执行结果、耗时、终端信息）实时推送到钉钉群机器人。

### 1.2 故障现象
在接入过程中，先后经历了多次反复与失效：
1. DSH 执行任务后，钉钉群机器人完全没有收到任何消息；
2. 中途排查时出现 DSH Desktop 报错退出、无法启动；
3. 一度出现 Codex Desktop 恢复但 DSH 仍然无响应；
4. 随后甚至 Codex 和 DSH 两端都再次收不到通知；
5. 直至最后精准定位多层隐蔽 Bug 并全量修复后，双端通知彻底恢复稳定。

---

## 2. 为什么改了这么多次？根因归类与全链路深度剖析

本次故障并非单一 Bug 引起，而是由 **多层分布式调用中的 4 个隐蔽缺陷 + 2 个排障中的衍生事故** 相互交织、层层掩盖造成的。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            全链路消息流向架构                               │
│                                                                             │
│  [DSH Desktop]                                                              │
│        │ (Cordis Event Bus)                                                 │
│        ▼ (Bug 1: Carrier Scope 过滤导致事件被静默丢弃)                      │
│  [dsh-vibe-notch Plugin]                                                    │
│        │ (Unix Domain Socket /tmp/claude-island.sock)                       │
│        ▼ (Bug 2: Socket 监听绑定在 UI onAppear，UI 未渲染则静默丢弃)         │
│  [HookSocketServer / SessionStore]                                          │
│        │ (zstd -dc 解压读取 ~/.dsh/sessions/.../session.jsonl.zstd)          │
│        ▼ (Bug 3: Process Pipe 满溢死锁，Actor 永久挂起！)                   │
│  [ConversationParser]                                                       │
│        │ (SessionStore.sessionsPublisher)                                   │
│        ▼ (Bug 4: 并发 Task 快照覆盖导致 previousPhase 为 nil)                │
│  [DingTalkNotificationCoordinator]                                          │
│        │ (HTTPS Webhook POST)                                               │
│        ▼                                                                    │
│  [DingTalk Robot API]                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 根因 1：DSH Cordis 框架的 Carrier Scope 作用域隔离（静默失效）
- **现象**：DSH 插件 apply(ctx) 正常执行了，但在会话生命周期中 ctx.on(session/event) 永远收不到 turn/start、turn/end 事件。
- **深层机理**：DSH 底层基于 Cordis 微内核架构。session/* 系列事件分发时携带了 session 内部的 carrier 作用域标识；Cordis 的事件分发器 EventsService.dispatch 会使用 filter.call(thisArg, hook.ctx) 校验监听者的 context 作用域。由于我们的插件是一个普通的扩展包，没有声明注入 sessions service，其 context 处于默认全局空间，被 carrier filter 视为非同域监听而**静默过滤**。
- **解决方式**：在所有的 ctx.on(session/..., callback, { global: true }) 中显式指定 { global: true }，强制越过作用域隔离。

---

### 根因 2：macOS Foundation Process 管道满溢死锁（导致 DSH 处理永久挂起）
这是导致 DSH 无法收到通知的**最隐蔽终极根因**。
- **现象**：Codex 能收到通知，但 DSH 只要一执行完，后台进程立即挂死，状态永远停留在 processing，无法进入 waitingForInput。
- **代码缺陷**：
  ```swift
  // 错误写法 (经典 Pipe Buffer Deadlock)
  try process.run()
  process.waitUntilExit() // 💥 子进程输出 > 64KB 时在此死等！
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  ```
- **深层机理**：
  DSH 会话日志采用 zstd 压缩存储，解压后包含所有 Skills 定义与系统上下文，单文件体积常达数十至数百 KB。
  macOS 系统管道缓冲区（Pipe Buffer）上限为 **64KB**。
  当 zstd -dc 向 stdout 输出超过 64KB 时，因缓冲区被填满，子进程被内核挂起等待父进程读取；而父进程此时正在执行 process.waitUntilExit() 等待子进程退出。
  **父子进程互相等待，发生永久死锁 (Deadlock)**！
  死锁导致 ConversationParser actor 阻塞，进而导致 SessionStore.processHookEvent 永远无法返回，整个 DSH 会话的状态机永久卡死。
- **解决方式**：
  调整顺序，**先 drain 管道数据流，再 wait 进程退出**：
  ```swift
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile() // 先读空缓冲区
  process.waitUntilExit()                                    // 子进程顺利写入完毕退出
  ```

---

### 根因 3：后台核心监控服务与 SwiftUI 视图生命周期的错误耦合
- **现象**：出现过 Codex 和 DSH 突然“两端都失效”的现象。
- **深层机理**：
  Socket 监听启动逻辑 ClaudeSessionMonitor.startMonitoring() 原先被写在 NotchView.onAppear 中。
  当应用在后台启动、以 Accessory 模式运行或刘海窗口处于非激活/闭合状态时，SwiftUI 的 onAppear 可能根本不会触发！
  这导致 HookSocketServer 虽然创建了 socket 文件，但其 eventHandler 实际上是 nil，所有来自外部的事件被直接吞掉。
- **解决方式**：
  解耦 UI 与后台服务：将 ClaudeSessionMonitor 提升为应用级全局单例，并在 AppDelegate.applicationDidFinishLaunching 中统一常驻启动。

---

### 根因 4：并发 Task 快照导致的会话状态竞态
- **现象**：日志中偶发 session cur=waitingForInput prev=nil，无法命中 prev != waitingForInput 完成条件。
- **深层机理**：
  SessionStore 在短时间内频繁触发 publishState() 时，Combine 订阅里的 Task { @MainActor in await processSnapshot() } 会产生多个并发执行的 Task。在包含 await 挂起点的情况下，后触发的 Task 可能先读取或覆盖 previousPhases，导致状态时序混乱。
- **解决方式**：
  在 Coordinator 中使用串行 Task 链（previousTask.value），强制保证快照处理的 FIFO 顺序。

---

### 衍生问题：排障过程中的环境与模板事故
1. **JS 模板展开语法错误**：
   在 Swift 代码中为 DSH 插件生成嵌入式 JS 代码时，多行字符串插值导致生成到磁盘的 
 被展开为真实换行，导致 DSH 报 SyntaxError: Invalid or unexpected token 退出。
2. **DSH 凭证文件格式严格性**：
   ~/.dsh/.credentials.yaml 中包含了嵌套结构，而 DSH 运行时的 dsh-credentials-local 严格要求根对象必须是 flat string mapping，导致 DSH 服务启动被拦截。

---

## 3. 经验总结与研发规范反思

### 3.1 为什么排查耗时较长？
1. **依赖假设而非客观事实**：早期过多假设“DSH 插件已经把事件送到 Socket 了，一定是 Swift 侧没解析”，或者“Swift 侧没收到一定是 Socket 挂了”，而没有在全链路第一时刻埋入端到端 Trace ID 和统一日志文件。
2. **静默失败（Silent Error Handling）的代价**：各层大量使用 catch { /* ignore */ } 或 try?，屏蔽了底层的真实错误。
3. **经典 IPC 陷阱的警惕性不足**：Foundation Process 的管道死锁是 Unix/macOS 系统编程中的经典陷阱，在大数据量测试前未被常规小数据单测暴露出来。

### 3.2 建立的长效机制与规范

| 维度 | 规范与改进措施 |
| :--- | :--- |
| **可观测性** | 引入统一全链路日志 /tmp/vibe-notch-flow.log，统一标注 [pid] [module] 与 event/status/sid，杜绝黑盒排查。 |
| **进程与管道** | 严格禁止在 Process 读取管道前调用 waitUntilExit()，一律采用先 drain 后 wait 范式，并设置超时保护。 |
| **架构分层** | 彻底剥离后台核心服务（Socket、Event Loop、Notifier）与 SwiftUI 渲染层的依赖，确保核心功能 100% 常驻高可用。 |
| **自动化测试** | 在单测套件中补充大体积会话（真实 zstd 数据包）的解析测试，确保边界数据量下的稳定运行。 |