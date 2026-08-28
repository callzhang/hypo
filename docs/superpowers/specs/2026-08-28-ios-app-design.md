# Hypo iOS 客户端设计文档

**日期**: 2026-08-28
**状态**: 已评审，待实现
**关联**: `docs/prd.md`、`docs/protocol.md`、`docs/technical.md`

---

## 1. 目标与范围

为 Hypo 增加 iOS 客户端，与现有 macOS、Android 客户端互通，复用同一套同步协议与后端 relay。

**第一版定位**：双向手动同步。

- **接收**：App 在前台时自动写入剪贴板；在后台或已被系统挂起时，经 APNs 推送唤醒 Notification Service Extension，解密后直接写入剪贴板。
- **发送**：由用户动作触发，提供三个入口——分享面板扩展、App 内 `UIPasteControl` 按钮、快捷指令（App Intents）。

**明确不做**（第一版）：键盘扩展；iOS 侧的 LAN 监听端（`LanWebSocketServer` 编译进来但不启动）；把 Android 并入跨平台框架。

### 1.1 为什么不是「移植 macOS 客户端」

iOS 不允许后台轮询剪贴板。macOS 的 `ClipboardMonitor` 依赖 `NSPasteboard.changeCount` 轮询，App 一进后台就被挂起，这条路在 iOS 上不存在。此外 iOS 16+ 读取非本 App 写入的 `UIPasteboard` 会弹系统授权提示。

因此 iOS 端的发送必然是用户主动触发的，接收在后台必须靠推送唤醒而非常驻连接。这是产品形态的改变，不只是 UI 移植。

---

## 2. 现状评估

### 2.1 代码耦合度

macOS 客户端共 51 个 Swift 文件，其中 16 个 `import AppKit`。实际耦合远比数字浅：

- **16 个中有 15 个的 `import AppKit` 已经被 `#if canImport(AppKit)` 包裹**——这个代码库为了 Linux 兼容早已建立了可移植性纪律（全包 200+ 处 `canImport` 判断）。`AppKit` 在 iOS 上不存在，因此这些文件在 iOS 上已经能编译。唯一的裸 import 是 `IncomingClipboardHandler.swift:2`。
- 所以第 1 期的工作**不是"让代码在 iOS 上编译通过"，而是"为那些在 iOS 上被条件编译掉的能力补上 iOS 实现"**——写剪贴板、应用生命周期观察、历史持久化。已有的 `canImport` 守卫是脚手架，不是终点。
- 真正的耦合有 5 处：`IncomingClipboardHandler`（写 `NSPasteboard`、`NSImage` 解码，且是裸 import）、`SecurityManager`（`copyEncryptionKeyToPasteboard`，已守卫）、`HistoryStore`（`ClipboardHistoryViewModel` 里写 pasteboard，已守卫）、`TempFileManager`（pasteboard 引用，已守卫）、`TransportManager`（私有类 `ApplicationLifecycleObserver` 监听 `NSApplication` 通知，已守卫）。
- `ConnectionStatusProber`、`PairingSession`、`MemoryProfiler` 的 `import AppKit` 确实没有任何 `NS*` 使用，但因为已被守卫，删除属于清理而非必需。
- 传输层核心（`SyncEngine`、`CloudRelayTransport`、`LanWebSocketTransport`、`TransportFrameCodec`、`WebSocketConnectionPool`）、`CryptoService`（CryptoKit，iOS 原生支持）、Models、Compression 全部零 AppKit 依赖。
- `LanWebSocketServer`（1235 行）用的是 Network.framework 的 `NWListener`，iOS 上同一套 API 可用；`BonjourPublisher`/`BonjourBrowser` 只依赖 Foundation/Darwin。

### 2.2 构建体系

macOS **没有 xcodeproj**。`macos/HypoApp.xcworkspace/contents.xcworkspacedata` 里只有一行 `Package.swift` 引用，是纯 SwiftPM 工程用 Xcode 打开。CI 走 `xcodebuild` 指向该 workspace，发布走 `scripts/build-macos.sh`（`swift build` 出二进制后脚本手工组 `.app` bundle）。

iOS 侧**必须**有 xcodeproj——App Extension、App Group、APNs capability 这些 SwiftPM 表达不了。因此最终形态是 macOS SwiftPM + iOS xcodeproj + 共享 local package，两套构建体系并存，**macOS 的构建、签名、CI 不做任何改动**。

### 2.3 协议兼容性

协议层几乎不用动：

- 后端 `backend/src/models/device.rs` 的 `Platform` enum 已包含 `Ios`。
- Android 的 `device_platform` 是裸字符串直接透传（`SyncModels.kt:35`）。
- macOS 的 `DevicePlatform` enum **已经有 `case iOS = "ios"`**（还有 `windows`、`linux`）。
- 唯一缺口：`DeviceIdentity.swift:26` 把当前平台硬编码为 `private static let currentPlatform = DevicePlatform.macOS`，需改成按 `#if os(iOS)` 判定。

### 2.4 后端现状

relay 是纯转发，无离线队列。目标设备不在线时直接向发送方回错误（`backend/src/handlers/websocket.rs:475`、`:584`）；`status.rs:69` 里的 `pending_messages: 0` 是占位说明，功能未实现。iOS 后台交付需要新增 APNs 通路（见 §6）。

### 2.5 Android 历史功能基线

iOS 是移动端，历史功能的参照系是 Android 而非 macOS 菜单栏工具。Android 用 Room 数据库，200 条上限，功能包括：搜索、置顶、按设备筛选、按类型筛选、单条/批量删除、清空、按时间清理、图片存本地文件路径、标记来源通道（LAN/CLOUD）、分页。

macOS 侧较简（`UserDefaults` 元数据 + Caches 目录 blob + 200 条上限 + 基础搜索）。**iOS 对齐 Android 的功能清单**，但存储实现不照搬 Room（见 §7.2）。

---

## 3. 架构决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 第一版定位 | 双向手动同步 | iOS 后台限制下能达到的最接近原生的体验 |
| 代码复用 | 抽出 `HypoCore` 跨平台 package | 耦合浅（5 个文件），现有 23 个测试文件可作回归网，协议演进只改一处 |
| LAN 角色 | iOS 只做发起端 | iOS 后台会挂起监听端口，当服务端会让对端频繁看到设备上下线 |
| 后台落盘 | NSE 静默写入剪贴板 | 体验最接近 Universal Clipboard；附带回读校验与降级链兜底 |
| 发送入口 | 分享扩展 + `UIPasteControl` + App Intents | 三者都不触发粘贴授权弹窗 |
| 历史存储 | 复用共享 `HistoryStore` 逻辑，iOS 换持久化实现 | Android 需要 Room 是因为后台服务与分页，iOS 无此压力 |
| 共享视图层 | 第一版不做，交付后作为独立一期 | 共享边界要在见过 iOS 界面之后才有依据（见 §3.1） |
| 跨平台框架 | 不采用 | 核心依赖全是平台 API，跨平台框架下框架层与原生层要各写一遍 |

### 3.1 关于「一个 app」

评估过把 macOS 与 iOS 合成单一 multiplatform target。结论是不划算：

macOS 约 4500 行 UI 代码中，`HypoMenuBarApp.swift`（3404 行）、`HistoryPopupPresenter.swift`（461 行）、两个右键菜单管理器（435 行）全是菜单栏形态特有的——`MenuBarExtra`、`NSStatusItem` 右键劫持、popover 定位、独立设置窗口，iOS 上一样都用不上。真正可跨的只有历史条目行渲染、内容类型徽章、预览卡片、配对界面、设置字段，约 800~1200 行，占 20~25%。

为这 20% 付出的代价是：macOS 构建/签名/CI/release workflow 全部重做，且 3404 行的菜单栏文件会被 `#if os(macOS)` 切碎。

更实质的障碍是交互形态：macOS 是菜单栏 popover（宽度固定且窄），靠右键菜单操作；iOS 是全屏列表，靠 swipe actions 和长按。硬共享的结果要么是两边都别扭的折中组件，要么是内部塞满条件编译——后者行数与各写一遍相当，还多背一层抽象。

**决定**：第一版只共享 `HypoCore`，iOS UI 独立写。iOS 交付后立即执行 `HypoUI` 抽取（§9 第 5 期，带验收标准），此时两边界面都已存在，共享边界看得见。

已知风险：「以后再合并」在实践中容易变成永不合并。缓解办法就是把它写成带验收标准的一期任务，而不是「后续优化」。

---

## 4. 代码结构

### 4.1 HypoCore

新建 `shared/` SwiftPM package，package 名 `HypoCore`，`platforms: [.macOS(.v13), .iOS(.v17)]`。macOS 与 iOS 均以本地依赖引用。不放在 `macos/` 目录下，因为它不再属于 macOS。

| 目录 | 内容（均来自现有文件） | 改动 |
|---|---|---|
| `Crypto/` | `CryptoService`、`DeviceKeyProvider`、`KeychainKeyStore`、`PairingSigningKeyStore`、`FileBasedKeyStore` | Keychain access group 参数化（扩展进程需读同一份密钥） |
| `Models/` | `ClipboardEntry`、`PairedDevice`、`DevicePlatform`、`DeviceIdentity` | `DeviceIdentity.currentPlatform` 改为按 `#if os(iOS)` 判定 |
| `Pairing/` | `PairingModels`、`PairingSession`、`PairingRelayClient` | 删除未使用的 `import AppKit` |
| `Transport/` | `TransportFrameCodec`、`WebSocketTransport`、`LanWebSocketTransport`、`CloudRelayTransport`、`DualSyncTransport`、`WebSocketConnectionPool`、`LanWebSocketServer`、`RateLimiter`、`TransportMetricsRecorder`、`TransportAnalytics` | `LanWebSocketServer` 在 iOS 编译但不启动 |
| `Discovery/` | `BonjourBrowser`、`BonjourPublisher` | 无 |
| `Sync/` | `SyncEngine`、`ClipboardEventDispatcher`、`IncomingClipboardHandler` | `IncomingClipboardHandler` 的 `NSPasteboard` 写入抽成协议 |
| `History/` | `HistoryStore`（actor 部分）、`OptimizedHistoryStore`、`StorageManager` | 持久化与存储目录参数化；`ClipboardHistoryViewModel` 不迁移 |
| `Utils/` | `Compression`、`SizeConstants`、`Logger`、`StringExtensions` | 无 |

### 4.2 平台适配协议

`HypoCore` 定义接口，两端各自实现：

- `ClipboardWriting` —— macOS: `NSPasteboard`；iOS: `UIPasteboard`
- `ClipboardMonitoring` —— macOS: `changeCount` 轮询；iOS: 空实现（发送由用户动作驱动）
- `AppLifecycleObserving` —— macOS: `NSApplication` 通知；iOS: `UIApplication` 通知
- `StorageLocations` —— macOS: Caches 目录；iOS: App Group 容器的 Application Support
- `HistoryPersistence` —— macOS: 现有 `UserDefaults` 实现（不改动）；iOS: App Group 容器内的原子 JSON 文件实现

### 4.3 macOS 侧改动范围

除了把文件搬进 `HypoCore`，macOS 侧有两类实质改动：

**一、把已有的条件编译守卫换成协议注入**——只涉及**迁入 `HypoCore` 且带 AppKit 耦合**的文件，共 2 处：`IncomingClipboardHandler`（`ClipboardWriting`）、`TransportManager`（`AppLifecycleObserving`）。macOS 的行为保持不变，只是实现从 `#if canImport(AppKit)` 内联代码变成注入的 macOS 实现。

`SecurityManager`、`TempFileManager`、`MemoryProfiler`、`ConnectionStatusProber`、`ClipboardMonitor`、`ClipboardNotificationController` 按 §4.1 的归位表**留在 `HypoApp`**，它们的 AppKit 用法在 macOS 目标内合法，第 1 期不改动。iOS 侧的等价能力属于第 2 期。

**二、拆分 `Services/HistoryStore.swift`（1187 行，两个职责）**：

- 第 24~218 行的 `public actor HistoryStore` —— 纯持久化，进 `HypoCore`
- 第 219~1187 行的 `ClipboardHistoryViewModel` —— macOS UI 层，依赖 `KeyboardShortcut`、`ClipboardMonitorDelegate`、`NSPasteboard`，**留在 `HypoApp`**

另有两处默认参数值需要解绑：`HistoryStore.swift:272` 和 `TransportManager.swift:116` 都把 `ClipboardNotificationScheduling`（已经是协议）的默认值写成了具体的 `ClipboardNotificationController.shared`。协议本身随文件进 `HypoCore`，默认值上移到 App 层。

`macos/Tests/HypoAppTests` 的 23 个测试文件是这次搬迁的回归网，全绿才算完成。

### 4.4 iOS 工程构成

`ios/Hypo.xcodeproj`，最低 iOS 17，四个部分：

- **主 App**（SwiftUI）：历史列表（搜索/置顶/按设备筛选/按类型筛选/删除/清空）、配对设备管理、连接状态、`UIPasteControl` 发送按钮、设置
- **Share Extension**：从任意 App 的分享面板发送文本/链接/图片/文件
- **Notification Service Extension**：接收 APNs 推送，解密后写入剪贴板
- **App Intents**：`SendClipboardIntent`，可绑定操作按钮、锁屏控件、自动化

三个进程共享 **App Group**（`group.com.hypo.clipboard`）和 **Keychain Sharing group**。后者是硬要求——扩展必须能独立解密，否则 NSE 拿到推送也解不开。两者都需要付费开发者账号的 Team ID。

---

## 5. 前台传输

与现有两端完全一致：`BonjourBrowser` 浏览 `_hypo._tcp.` 发现对端 → LAN WebSocket 直连；发现不到或跨网段 → fallback 到 `hypo.fly.dev` relay。iOS 只做发起端。

iOS 特有配置：`NSLocalNetworkUsageDescription`、`NSBonjourServices: [_hypo._tcp]`。

**必须处理的 iOS 坑**：首次浏览会弹「本地网络」权限窗，用户拒绝后 Bonjour 静默失效且不报错。设置页必须显式展示「本地网络：未授权（当前仅云端同步）」并提供跳转系统设置的引导，否则用户只会觉得 LAN 莫名其妙不生效。

---

## 6. 后台交付（APNs）

### 6.1 后端改动

1. `POST /devices/{id}/apns` —— 注册 device token（含 bundle id 与 environment），存 Redis。
2. 转发失败分支（`websocket.rs:475`、`:584`）：目标离线但已注册 APNs token 时，把密文暂存 Redis（TTL 10 分钟）并发送推送，向发送方返回 `queued` 而非错误。
3. `GET /messages/{id}` —— 供 NSE 拉取暂存密文，凭 device 身份鉴权。
4. 新依赖：APNs 客户端。采用 `reqwest` + ES256 JWT 的 token-based auth，不使用证书，比引入 `a2` 更轻。

### 6.2 载荷分档

APNs 载荷上限 4KB，据此分三档：

下表的大小口径统一为**密文 base64 编码后的字节数**：

| 密文 base64 后大小 | 策略 |
|---|---|
| ≤ 2.5KB（约 1.8KB 原文） | 直接放入推送载荷，NSE 本地解密，零网络往返 |
| 2.5KB ~ 1MB | 推送只带 message id，NSE 经 `GET /messages/{id}` 回源拉取后解密 |
| > 1MB | 只推通知不落盘，等用户打开 App 走正常通道同步 |

1MB 阈值的依据：NSE 只有约 30 秒执行预算，10MB 图片在蜂窝网下大概率超时。

### 6.3 降级链

NSE 解密并写入 `UIPasteboard` → 立即回读校验 → 校验失败则改发带「复制」动作的通知 → 用户点击后 App 被后台唤起写入 → 仍失败则内容保留在历史中，打开 App 可手动复制。

任何一环断掉都不会静默丢内容。这条降级链同时是对未文档化行为的对冲：**在 App Extension 中写入 `UIPasteboard` 是未文档化行为**，Apple 从未保证扩展能修改通用剪贴板，iOS 大版本更新可能收紧。

### 6.4 隐私影响

走 APNs 意味着推送经过 Apple 的服务器。内容仍是端到端加密的，Apple 只看到密文与 device token；但元数据会暴露——谁在什么时候发了东西、多大。这与现在经 fly.io relay 的暴露面是同一量级，不更差，但需写入用户文档。

---

## 7. 数据

### 7.1 存储位置

- **App Group 容器** `group.com.hypo.clipboard`：图片与文件 blob 放 `Application Support/`
- **Keychain access group**：配对密钥与签名密钥

**不使用 Caches 目录**：iOS 在存储紧张时会清理 Caches，图片会莫名消失。这与 macOS 的现有行为（`StorageManager` 用 `~/Library/Caches`）不同，是 iOS 侧必须的偏离。

### 7.2 跨进程并发

主 App、Share Extension、NSE 三个进程都会写历史。`UserDefaults` 的 App Group suite 跨进程不可靠——一个进程的写入另一个进程未必及时看到，KVO 也不跨进程。

因此 `HypoCore` 定义 `HistoryPersistence` 协议：

- macOS 注入现有 `UserDefaults` 实现，**行为完全不变**
- iOS 注入 App Group 容器内的原子 JSON 文件实现，用 `NSFileCoordinator` 保护读写，用文件监听做跨进程变更通知

### 7.3 历史功能

对齐 Android 的功能清单：搜索、置顶、按设备筛选、按类型筛选、单条删除、批量删除、清空、来源通道标记（LAN/CLOUD）、200 条上限。搜索与筛选在 200 条内存数据上做，不需要数据库。

---

## 8. 错误处理

每一条都必须有 UI 呈现，不允许静默失败：

| 情况 | 处理 |
|---|---|
| 本地网络权限被拒 | 降级为仅云端；设置页明示状态并给跳转引导 |
| 通知权限被拒 | 后台完全收不到内容；设置页明示后果 |
| APNs token 失效 | 重新注册 |
| relay 不可达 | 指数退避重连；UI 显示离线状态 |
| 未配对 | 引导进入配对流程 |
| 内容超 `SizeConstants.maxAttachmentBytes`（10MB） | 按现有常量拒绝并提示 |
| NSE 执行超时 | 降级为带「复制」动作的通知 |
| 解密失败（密钥轮换后的旧推送） | 丢弃并提示重新配对 |

---

## 9. 分期计划

刻意让「付费开发者账号未定」只卡住第 3 期以后，前两期立刻可开工。

| 期 | 内容 | 验收标准 | 需付费账号 |
|---|---|---|---|
| 1 | `HypoCore` 抽取（不含任何 iOS 代码） | `macos/Tests/HypoAppTests` 23 个测试文件全绿；macOS 构建脚本与 CI 未改动 | 否 |
| 2 | iOS 前台版：主 App、配对、LAN+云双通道、历史、`UIPasteControl` 发送 | 模拟器与 macOS 双向同步成功；本地网络权限被拒时降级正确 | 否 |
| 3 | Share Extension、App Intents、App Group、Keychain sharing | 分享面板发送文本/图片/文件成功；扩展能独立解密 | 是 |
| 4 | APNs 后台落盘：后端改造 + NSE + 降级链 | 杀进程状态下收到推送并落盘；三档载荷策略各自验证；降级链每一环可复现 | 是 |
| 5 | `HypoUI` 抽取 | 双端共用同一组件；macOS 菜单栏无回归 | 否 |

---

## 10. 测试策略

- **HypoCore 抽取回归**：现有 23 个测试文件全绿，这是第 1 期的唯一验收口径
- **跨平台一致性**：为 `HypoCore` 增加 iOS 测试目标，跑同一套逻辑测试，验证 iOS 上行为一致
- **协议 fixture**：复用 `tests/transport/*.json` 校验帧编解码与加密向量
- **后端**：APNs 通路加集成测试，mock APNs endpoint
- **手工验收**：iOS↔macOS、iOS↔Android 各自覆盖前台 / 后台 / 杀进程三态

**已知覆盖缺口**：macOS UI 层零测试覆盖（23 个测试文件全是逻辑层）。第 5 期 `HypoUI` 抽取要动 macOS 视图代码时没有自动化兜底，只能人工验证菜单栏行为——这是该期的主要风险，需在执行时安排明确的手工回归清单。

---

## 11. 未决事项

- **Apple Developer Program 账号**：本文档按已有付费账号设计。若最终只有免费账号，第 3、4 期无法执行（无 App Groups、无 APNs），iOS 端将退化为「仅前台、无扩展」的形态，需重新评审。
- **分发目标**：TestFlight/App Store 还是仅自用真机。若上架，需额外处理剪贴板相关的审核说明、隐私清单（Privacy Manifest）、本地网络权限文案。
