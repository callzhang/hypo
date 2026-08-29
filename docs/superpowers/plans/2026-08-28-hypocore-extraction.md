# HypoCore 抽取实现计划（iOS 第 1 期）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 macOS 客户端中与平台无关的逻辑抽成 `HypoCore` 跨平台 SwiftPM package，使其能同时为 macOS 与 iOS 构建，且 macOS 端行为与测试完全不变。

**Architecture:** 新建 `shared/HypoCore/` package（`platforms: [.macOS(.v13), .iOS(.v17)]`），`macos/Package.swift` 以本地路径依赖它。文件按依赖顺序自底向上分批 `git mv`，每批之后跑完整测试套件。三处 AppKit 耦合改为协议注入，macOS 实现留在 `HypoApp`。`Services/HistoryStore.swift` 按职责拆分：`HistoryStore` actor 进 core，`ClipboardHistoryViewModel` 留在 app。

**Tech Stack:** Swift 6 / SwiftPM (tools-version 6.0) / swift-testing 0.5.0 / Network.framework / CryptoKit

**参考文档:** `docs/superpowers/specs/2026-08-28-ios-app-design.md`（§2、§4）

---

## 关键约定

**每个任务结束时测试必须全绿。** 验证命令固定为：

```bash
cd macos && swift test 2>&1 | tail -20
```

期望输出结尾包含 `Test run with N tests passed`，且 N ≥ 193。

**本机没有 Xcode。** `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，`/Applications` 下无 `Xcode.app`，因此**没有 iOS SDK、没有模拟器、`xcodebuild` 不可用**。SwiftPM 也无法绕过：交叉编译到 iOS 需要随 Xcode 分发的 iOS SDK。

因此 iOS 验证分成两层：

**本地可移植性闸门**（每个搬迁任务都要跑）：

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。这不能证明 iOS 构建成功，但能在本地立刻抓住最可能的破坏源——把 macOS 专有类型带进了 core。

**CI 上的权威验证**：Task 1B 新增的 `ios-core-build` job 在 `macos-15` runner 上跑真正的 `xcodebuild`。**每个任务提交后都要推送并确认该 job 通过**，不要攒着一次推。

**基线**：抽取开始前 `cd macos && swift test` 的结果是 `✔ Test run with 193 tests passed after 5.699 seconds.`（2026-08-28 实测）。任务过程中通过数只应增加，不应减少。

**为什么 package 放在 `shared/HypoCore/` 而不是 `shared/`**：SwiftPM 对本地路径依赖使用目录名作为 package identity。放在 `shared/` 会得到 identity `shared`，产品引用要写成 `.product(name: "HypoCore", package: "shared")`，易错。放在 `shared/HypoCore/` 则 identity 与 package 名一致。第 5 期的 `HypoUI` 将来放 `shared/HypoUI/`。

**关于 `unsafeFlags`**：`macos/Package.swift` 现有的 `.unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))` **不要复制到 HypoCore**。tools-version 6.0 的 target 默认就是 Swift 6 语言模式，严格并发检查已默认开启；且带 `unsafeFlags` 的 package 无法被版本化依赖引用，会给将来留坑。

---

## 文件结构

### 新建

| 路径 | 职责 |
|---|---|
| `shared/HypoCore/Package.swift` | package 定义，双平台声明 |
| `shared/HypoCore/Sources/HypoCore/Platform/ClipboardWriting.swift` | 剪贴板写入协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/AppLifecycleObserving.swift` | 应用生命周期观察协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/HistoryPersistence.swift` | 历史持久化协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/StorageLocations.swift` | 存储目录协议 |
| `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift` | 从具体控制器中提取的协议声明 |
| `shared/HypoCore/Tests/HypoCoreTests/` | Task 15 迁入的 core 测试 |
| `macos/Sources/HypoApp/HypoCoreExport.swift` | `@_exported import HypoCore`，使 app 与测试代码无需逐文件加 import |
| `macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift` | `ClipboardWriting` 的 macOS 实现 |
| `macos/Sources/HypoApp/Platform/AppKitLifecycleObserver.swift` | `AppLifecycleObserving` 的 macOS 实现 |
| `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift` | 从 `HistoryStore.swift` 拆出的 macOS UI 层 |

### 迁入 HypoCore（按任务顺序）

| 目标目录 | 文件 |
|---|---|
| `Utils/` | `Compression.swift`、`SizeConstants.swift`、`Logger.swift`、`StringExtensions.swift` |
| `Models/` | `ClipboardEntry.swift`、`PairedDevice.swift`、`DeviceIdentity.swift` |
| `Crypto/` | `CryptoService.swift`、`DeviceKeyProvider.swift`、`FileBasedKeyStore.swift`、`FileBasedPairingSigningKeyStore.swift`、`KeychainKeyStore.swift`、`PairingSigningKeyStore.swift` |
| `Discovery/` | `BonjourBrowser.swift`、`BonjourPublisher.swift` |
| `Transport/` | `TransportFrameCodec.swift`、`RateLimiter.swift`、`WebSocketTransport.swift`、`WebSocketConnectionPool.swift`、`TransportMetricsRecorder.swift`、`TransportAnalytics.swift`、`LanWebSocketTransport.swift`、`LanWebSocketServer.swift`、`LanSyncTransport.swift`、`CloudRelayTransport.swift`、`CloudRelayConfiguration+Defaults.swift`、`DualSyncTransport.swift`、`TransportProvider+Default.swift`、`TransportManager.swift`、`ConnectionStatusProber.swift` |
| `Pairing/` | `PairingModels.swift`、`PairingSession.swift`、`PairingRelayClient.swift` |
| `Sync/` | `SyncEngine.swift`、`ClipboardEventDispatcher.swift`、`IncomingClipboardHandler.swift` |
| `History/` | `HistoryStore.swift`（仅 actor 部分）、`OptimizedHistoryStore.swift`、`StorageManager.swift` |
| `Files/` | `TempFileManager.swift` |

### 关于 `ClipboardMonitoring` 协议

spec §4.2 列了 4 个平台适配协议，本计划只建 3 个（`ClipboardWriting`、`AppLifecycleObserving`、`StorageLocations`、`HistoryPersistence` 中的后三个加第一个，共 4 个文件），**唯独不建 `ClipboardMonitoring`**。

原因：它唯一的消费方 `ClipboardMonitor.swift` 第 1 期不迁入 `HypoCore`（见下方「留在 HypoApp」），`HypoCore` 里没有任何代码需要这个抽象。第 1 期就定义一个无人使用的协议属于为想象中的需求写代码。它在第 2 期随 iOS 的剪贴板采集路径一起建立——那时才知道 iOS 侧真正需要什么形状（iOS 没有轮询，采集由分享扩展、`UIPasteControl`、App Intents 三个入口驱动，与 macOS 的 `changeCount` 轮询不是同一个接口）。

### 留在 HypoApp

`App/` 下 6 个文件、`ClipboardMonitor.swift`、`ClipboardNotificationController.swift`、`SecurityManager.swift`、`MemoryProfiler.swift`、`RemotePairingViewModel.swift`、拆分产生的 `ClipboardHistoryViewModel.swift`、两个平台协议实现。

---

## Task 1: 建立 HypoCore package 骨架

**Files:**
- Create: `shared/HypoCore/Package.swift`
- Create: `shared/HypoCore/Sources/HypoCore/HypoCore.swift`

- [ ] **Step 1: 创建目录与 package 定义**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore
```

写入 `shared/HypoCore/Package.swift`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HypoCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HypoCore",
            targets: ["HypoCore"]
        )
    ],
    targets: [
        .target(
            name: "HypoCore",
            path: "Sources/HypoCore",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ]
)
```

- [ ] **Step 2: 写入占位源文件**

`shared/HypoCore/Sources/HypoCore/HypoCore.swift`：

```swift
import Foundation

/// Marker for the shared cross-platform core. Replaced by real content as
/// files migrate in from the macOS target.
public enum HypoCore {
    public static let moduleName = "HypoCore"
}
```

- [ ] **Step 3: 验证 macOS 构建**

```bash
cd shared/HypoCore && swift build 2>&1 | tail -3
```

期望：`Build complete!`

- [ ] **Step 4: 确认本地无法验证 iOS**

```bash
xcodebuild -version 2>&1 | head -2
```

期望：报错 `tool 'xcodebuild' requires Xcode`。这是已知状态，不是故障——iOS 构建验证由 Task 1B 建立的 CI job 承担。确认后继续。

- [ ] **Step 5: 提交**

```bash
git add shared/HypoCore
git commit -m "build(shared): add HypoCore cross-platform package skeleton"
```

- [ ] **Step 6: 忽略新的构建产物路径**

`swift build` 会生成 `shared/HypoCore/.build/`。现有 `.gitignore` 只忽略 `macos/.build/`，不补规则的话它会在后续每个任务里污染 `git status`。追加两行：

```
shared/**/.build/
shared/**/Package.resolved
```

单独提交，不要混进 Step 5 的提交：

```bash
git add .gitignore
git commit -m "chore: ignore HypoCore build artifacts"
```

- [ ] **Step 7: 确认工作区干净**

```bash
git status --short
```

期望：无输出。每个任务结束时工作区都必须干净，不允许留未提交的改动。

---

## Task 1B: 建立 iOS 构建的 CI 验证

本机无 Xcode，iOS 构建的权威结论只能来自 CI。必须在开始搬迁**之前**把这条通路建好，否则 17 个任务搬完才发现某个文件在 iOS 上编译不过，返工成本极高。

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: 新增 ios-core-build job**

在 `.github/workflows/ci.yml` 的 `jobs:` 下追加（与 `macos-tests` 同级，缩进 2 空格）：

```yaml
  ios-core-build:
    name: HypoCore iOS Build
    runs-on: macos-15
    timeout-minutes: 15

    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Show available iOS SDKs
        run: xcodebuild -showsdks | grep -i ios
      - name: Build HypoCore for iOS Simulator
        working-directory: shared/HypoCore
        run: |
          xcodebuild build \
            -scheme HypoCore \
            -destination 'generic/platform=iOS Simulator' \
            -skipMacroValidation
      - name: Build HypoCore for macOS
        working-directory: shared/HypoCore
        run: swift build
```

`macos-15` runner 自带 Xcode 与 iOS SDK，与现有 `macos-tests` job 用的是同一类 runner。

- [ ] **Step 2: 本地校验 YAML 语法**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(sorted(d['jobs'].keys()))"
```

期望：输出的 job 列表包含 `ios-core-build`，且不抛异常。若本机无 PyYAML，先 `pip3 install pyyaml`。

- [ ] **Step 3: 提交并推送**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build HypoCore for iOS on every push"
git push -u origin feat/ios-hypocore
```

- [ ] **Step 4: 确认 CI 通过**

```bash
gh run list --branch feat/ios-hypocore --limit 3
```

等到 `HypoCore iOS Build` 显示 `success`。失败则先读日志修好再进入 Task 2——**这条通路不通，后续所有任务的 iOS 验证都是空的**。

```bash
gh run view --log-failed
```

---

## Task 2: 接通依赖管道（零文件迁移）

**本任务附带三个已定的 CI 决策**（由 Task 1B 的质量审查提出，理由已记录，实现时照做即可）：

1. **保留 `ios-core-build` 里的 `Build HypoCore for macOS` 步骤。** 本任务之后 `macos-tests` 会连带构建 HypoCore，二者确实重复，但该步骤与 iOS 构建同在一个 job 内，不额外占用 runner，且 `swift build` 一个小包只需数秒。保留的价值是归因清晰：这一步红了就是「HypoCore 自身构建不过」，而不是「macOS App 哪里坏了」。在 15 个搬迁任务期间这个区分值这点开销。Task 17 复核时再评估是否撤除。

2. **加 workflow 级并发取消，但在 `main` 上不生效，且作为独立提交。** Task 1B 的实现者拒绝把它折进那个提交，两条理由均成立：`ci.yml` 的 `push` 触发器是 `branches: ["**"]`，包含 `main`，无条件的 `cancel-in-progress: true` 会让 `main` 上连续推送时前一次 CI 被杀掉；且顶层块虽不改三个既有 job 的 YAML 文本，却改变其运行时行为，而 Task 17 要验收那三个 job 未被修改。已确认无跨 workflow 风险（`backend-deploy.yml`、`release.yml` 是独立 workflow，并发组按 workflow 自动隔离；无任何 `needs:`/`workflow_run` 依赖 `ci.yml`）。

   用表达式把 `main` 排除掉，反对意见即消解——特性分支上取消陈旧运行，`main` 上行为与今天完全一致：

   ```yaml
   concurrency:
     group: ${{ github.workflow }}-${{ github.ref }}
     cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
   ```

   放在 `on:` 块之后、`jobs:` 之前，列 0 缩进。**必须单独提交**（`ci: cancel superseded runs on feature branches`），不要与本任务的依赖接线混在一起。Task 17 的验收口径已相应放宽（见该任务）。

3. **不锁定 Xcode 版本。** `runs-on: macos-15` 用镜像默认 Xcode（当前 16.4，随附 iPhoneSimulator18.5.sdk）。风险确实存在——GitHub 中途升级默认 Xcode 会产生与搬迁内容无关的失败。但既有的 `macos-tests` 同样没锁，只锁新 job 会造成两个 job 行为不一致，反而更难排查；且第 1 期预计在较短周期内完成。维持现状，若真的遇到 Xcode 漂移再一次性给两个 job 都锁上。

**已验证的事实**：`macos-15` runner 上可用的 iPhone 模拟器机型包括 `iPhone 16`、`iPhone 16 Plus`、`iPhone 16 Pro`、`iPhone 16 Pro Max`、`iPhone 16e`，以及 11~15 各代（CI run 33234196993 实测）。因此 Task 16 硬编码的 `name=iPhone 16` 可用，无需回退方案。

**Files:**
- Modify: `macos/Package.swift`
- Create: `macos/Sources/HypoApp/HypoCoreExport.swift`

- [ ] **Step 1: 在 macos/Package.swift 中加入本地依赖**

把 `dependencies` 数组改为：

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0"),
        .package(path: "../shared/HypoCore")
    ],
```

把 `HypoApp` target 的 `dependencies` 改为：

```swift
            dependencies: [
                .product(name: "HypoCore", package: "HypoCore")
            ],
```

- [ ] **Step 2: 加入再导出文件**

`macos/Sources/HypoApp/HypoCoreExport.swift`：

```swift
// Re-exports HypoCore so that existing HypoApp sources and the 23 test files
// keep compiling without adding a per-file `import HypoCore`.
@_exported import HypoCore
```

- [ ] **Step 3: 运行测试确认未破坏现状**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全部通过，通过数与接线前一致。

- [ ] **Step 4: 确认再导出生效**

在 `macos/Tests/HypoAppTests/CryptoServiceTests.swift` 顶部临时加一行 `_ = HypoCore.moduleName` 到任一测试函数体内并运行该测试，确认能解析到 `HypoCore` 类型：

```bash
cd macos && swift test --filter CryptoServiceTests 2>&1 | tail -5
```

期望：PASS。确认后**撤销这行临时代码**。

- [ ] **Step 5: 提交**

```bash
git add macos/Package.swift macos/Sources/HypoApp/HypoCoreExport.swift
git commit -m "build(macos): depend on HypoCore and re-export it"
```

---

## Task 3: 迁移 Utils 层

零依赖的四个文件，先搬最底层。

**Files:**
- Move: `macos/Sources/HypoApp/Utils/Compression.swift` → `shared/HypoCore/Sources/HypoCore/Utils/Compression.swift`
- Move: `macos/Sources/HypoApp/Utils/SizeConstants.swift` → `shared/HypoCore/Sources/HypoCore/Utils/SizeConstants.swift`
- Move: `macos/Sources/HypoApp/Utilities/Logger.swift` → `shared/HypoCore/Sources/HypoCore/Utils/Logger.swift`
- Move: `macos/Sources/HypoApp/Utilities/StringExtensions.swift` → `shared/HypoCore/Sources/HypoCore/Utils/StringExtensions.swift`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Utils
git mv macos/Sources/HypoApp/Utils/Compression.swift shared/HypoCore/Sources/HypoCore/Utils/Compression.swift
git mv macos/Sources/HypoApp/Utils/SizeConstants.swift shared/HypoCore/Sources/HypoCore/Utils/SizeConstants.swift
git mv macos/Sources/HypoApp/Utilities/Logger.swift shared/HypoCore/Sources/HypoCore/Utils/Logger.swift
git mv macos/Sources/HypoApp/Utilities/StringExtensions.swift shared/HypoCore/Sources/HypoCore/Utils/StringExtensions.swift
```

- [ ] **Step 2: 删除占位文件**

Task 1 建的 `Sources/HypoCore/HypoCore.swift` 只是为了让 target 有源文件。本任务搬进 4 个真文件后它就没用了，且它的类型名与模块同名（`HypoCore.HypoCore`），留着会变成死代码。Task 2 的再导出验证已经用完它了，现在删：

```bash
git rm shared/HypoCore/Sources/HypoCore/HypoCore.swift
```

- [ ] **Step 3: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿。若报某个符号不可见，说明该符号缺少 `public` 修饰——为它加上 `public`，不要改回内部可见性，也不要把文件搬回去。

- [ ] **Step 4: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor(core): move utility layer into HypoCore"
```

---

## Task 4: 迁移 Models 与设备标识

**Files:**
- Move: `macos/Sources/HypoApp/Models/ClipboardEntry.swift` → `shared/HypoCore/Sources/HypoCore/Models/ClipboardEntry.swift`
- Move: `macos/Sources/HypoApp/Models/PairedDevice.swift` → `shared/HypoCore/Sources/HypoCore/Models/PairedDevice.swift`
- Move: `macos/Sources/HypoApp/Services/DeviceIdentity.swift` → `shared/HypoCore/Sources/HypoCore/Models/DeviceIdentity.swift`
- Test: `shared/HypoCore/Tests/HypoCoreTests/DevicePlatformTests.swift`（Task 15 才建目录，此处先把测试写进 `macos/Tests/HypoAppTests/DeviceIdentityPlatformTests.swift`）

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Models
git mv macos/Sources/HypoApp/Models/ClipboardEntry.swift shared/HypoCore/Sources/HypoCore/Models/ClipboardEntry.swift
git mv macos/Sources/HypoApp/Models/PairedDevice.swift shared/HypoCore/Sources/HypoCore/Models/PairedDevice.swift
git mv macos/Sources/HypoApp/Services/DeviceIdentity.swift shared/HypoCore/Sources/HypoCore/Models/DeviceIdentity.swift
```

- [ ] **Step 2: 写失败测试——当前平台判定**

创建 `macos/Tests/HypoAppTests/DeviceIdentityPlatformTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoApp

@Suite("DeviceIdentity platform detection")
struct DeviceIdentityPlatformTests {
    @Test("currentPlatform matches the compiled platform")
    func currentPlatformMatchesCompiledPlatform() {
        #if os(iOS)
        #expect(DeviceIdentity.currentPlatform == .iOS)
        #else
        #expect(DeviceIdentity.currentPlatform == .macOS)
        #endif
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

```bash
cd macos && swift test --filter DeviceIdentityPlatformTests 2>&1 | tail -10
```

期望：编译失败，`'currentPlatform' is inaccessible due to 'private' protection level`。

- [ ] **Step 4: 改为按平台判定并放开可见性**

在 `shared/HypoCore/Sources/HypoCore/Models/DeviceIdentity.swift` 中，把第 26 行

```swift
    private static let currentPlatform = DevicePlatform.macOS
```

替换为：

```swift
    public static let currentPlatform: DevicePlatform = {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }()
```

- [ ] **Step 5: 运行测试确认通过**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，且新增的 `DeviceIdentityPlatformTests` 通过。

- [ ] **Step 6: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor(core): move models and make platform detection compile-time"
```

---

## Task 5: 迁移 Crypto 层

**Files:**
- Move: `macos/Sources/HypoApp/Crypto/*.swift`（6 个文件）→ `shared/HypoCore/Sources/HypoCore/Crypto/`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Crypto
git mv macos/Sources/HypoApp/Crypto/CryptoService.swift shared/HypoCore/Sources/HypoCore/Crypto/CryptoService.swift
git mv macos/Sources/HypoApp/Crypto/DeviceKeyProvider.swift shared/HypoCore/Sources/HypoCore/Crypto/DeviceKeyProvider.swift
git mv macos/Sources/HypoApp/Crypto/FileBasedKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/FileBasedKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/FileBasedPairingSigningKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/FileBasedPairingSigningKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/KeychainKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/KeychainKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/PairingSigningKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/PairingSigningKeyStore.swift
```

- [ ] **Step 2: 确认 Keychain access group 已就绪（无需改动）**

`KeychainKeyStore.swift:16` 的初始化器已经是 `public init(service: String = "com.hypo.clipboard.keys", accessGroup: String? = nil)`，且第 99 行已在 `accessGroup` 非 nil 时写入 `kSecAttrAccessGroup`。iOS 扩展共享密钥所需的参数化**已经存在**，本任务不改这个文件。

用以下命令确认后直接进入下一步：

```bash
grep -n "accessGroup" shared/HypoCore/Sources/HypoCore/Crypto/KeychainKeyStore.swift
```

期望：能看到 `init(... accessGroup: String? = nil)` 与 `query[kSecAttrAccessGroup as String] = accessGroup`。

- [ ] **Step 3: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿。`CryptoServiceTests` 必须通过——它校验的是与 Android 互通的加密行为，一旦回归就是协议级故障。

- [ ] **Step 4: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor(core): move crypto layer into HypoCore"
```

---

## Task 6: 迁移 Bonjour 发现层

**Files:**
- Move: `macos/Sources/HypoApp/Utilities/BonjourBrowser.swift` → `shared/HypoCore/Sources/HypoCore/Discovery/BonjourBrowser.swift`
- Move: `macos/Sources/HypoApp/Utilities/BonjourPublisher.swift` → `shared/HypoCore/Sources/HypoCore/Discovery/BonjourPublisher.swift`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Discovery
git mv macos/Sources/HypoApp/Utilities/BonjourBrowser.swift shared/HypoCore/Sources/HypoCore/Discovery/BonjourBrowser.swift
git mv macos/Sources/HypoApp/Utilities/BonjourPublisher.swift shared/HypoCore/Sources/HypoCore/Discovery/BonjourPublisher.swift
```

- [ ] **Step 2: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `BonjourBrowserTests` 与 `BonjourPublisherTests`。

- [ ] **Step 3: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor(core): move bonjour discovery into HypoCore"
```

---

## Task 7: 迁移传输层基础组件

**Files:**
- Move 6 个文件 → `shared/HypoCore/Sources/HypoCore/Transport/`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Transport
git mv macos/Sources/HypoApp/Services/TransportFrameCodec.swift shared/HypoCore/Sources/HypoCore/Transport/TransportFrameCodec.swift
git mv macos/Sources/HypoApp/Services/RateLimiter.swift shared/HypoCore/Sources/HypoCore/Transport/RateLimiter.swift
git mv macos/Sources/HypoApp/Services/WebSocketTransport.swift shared/HypoCore/Sources/HypoCore/Transport/WebSocketTransport.swift
git mv macos/Sources/HypoApp/Services/WebSocketConnectionPool.swift shared/HypoCore/Sources/HypoCore/Transport/WebSocketConnectionPool.swift
git mv macos/Sources/HypoApp/Services/TransportMetricsRecorder.swift shared/HypoCore/Sources/HypoCore/Transport/TransportMetricsRecorder.swift
git mv macos/Sources/HypoApp/Services/TransportAnalytics.swift shared/HypoCore/Sources/HypoCore/Transport/TransportAnalytics.swift
```

- [ ] **Step 2: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `TransportFrameCodecTests`、`TokenBucketTests`、`WebSocketTransportTests`、`TransportMetricsAggregatorTests`。

- [ ] **Step 3: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor(core): move transport primitives into HypoCore"
```

---

## Task 8: 迁移具体传输实现

**Files:**
- Move 7 个文件 → `shared/HypoCore/Sources/HypoCore/Transport/`

- [ ] **Step 1: 移动文件**

```bash
git mv macos/Sources/HypoApp/Services/LanWebSocketTransport.swift shared/HypoCore/Sources/HypoCore/Transport/LanWebSocketTransport.swift
git mv macos/Sources/HypoApp/Services/LanWebSocketServer.swift shared/HypoCore/Sources/HypoCore/Transport/LanWebSocketServer.swift
git mv macos/Sources/HypoApp/Services/LanSyncTransport.swift shared/HypoCore/Sources/HypoCore/Transport/LanSyncTransport.swift
git mv macos/Sources/HypoApp/Services/CloudRelayTransport.swift shared/HypoCore/Sources/HypoCore/Transport/CloudRelayTransport.swift
git mv "macos/Sources/HypoApp/Services/CloudRelayConfiguration+Defaults.swift" "shared/HypoCore/Sources/HypoCore/Transport/CloudRelayConfiguration+Defaults.swift"
git mv macos/Sources/HypoApp/Services/DualSyncTransport.swift shared/HypoCore/Sources/HypoCore/Transport/DualSyncTransport.swift
git mv "macos/Sources/HypoApp/Services/TransportProvider+Default.swift" "shared/HypoCore/Sources/HypoCore/Transport/TransportProvider+Default.swift"
```

- [ ] **Step 2: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `LanWebSocketTransportTests`、`LanWebSocketServerTests`、`LanWebSocketServerBufferTests`、`LanSyncTransportTests`、`CloudRelayTransportTests`。

- [ ] **Step 3: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。。`LanWebSocketServer.swift` 用的是 `NWListener`，iOS 上可编译；它在 iOS 上不启动是运行时决策（第 2 期），不是编译期决策。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor(core): move LAN and cloud transports into HypoCore"
```

---

## Task 9: 迁移配对层

**Files:**
- Move: `macos/Sources/HypoApp/Pairing/PairingModels.swift`、`PairingSession.swift`、`macos/Sources/HypoApp/Services/PairingRelayClient.swift` → `shared/HypoCore/Sources/HypoCore/Pairing/`

`Pairing/RemotePairingViewModel.swift` **不迁移**——它是 macOS UI 层。

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Pairing
git mv macos/Sources/HypoApp/Pairing/PairingModels.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingModels.swift
git mv macos/Sources/HypoApp/Pairing/PairingSession.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingSession.swift
git mv macos/Sources/HypoApp/Services/PairingRelayClient.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingRelayClient.swift
```

- [ ] **Step 2: 删除 PairingSession 中未使用的 AppKit import**

`PairingSession.swift` 第 3~5 行形如：

```swift
#if canImport(AppKit)
import AppKit
#endif
```

整段删除。该文件没有任何 `NS*` 类型使用（已核实）。

- [ ] **Step 3: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `PairingSessionTests`。

- [ ] **Step 4: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor(core): move pairing layer into HypoCore"
```

---

## Task 10: 迁移存储层并抽出 StorageLocations 协议

`StorageManager.swift:23` 硬编码 `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!`。iOS 上 Caches 会被系统清理（spec §7.1），必须可注入。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/Platform/StorageLocations.swift`
- Move: `macos/Sources/HypoApp/Services/StorageManager.swift` → `shared/HypoCore/Sources/HypoCore/History/StorageManager.swift`
- Move: `macos/Sources/HypoApp/Services/OptimizedHistoryStore.swift` → `shared/HypoCore/Sources/HypoCore/History/OptimizedHistoryStore.swift`
- Test: `macos/Tests/HypoAppTests/StorageLocationsTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `macos/Tests/HypoAppTests/StorageLocationsTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoApp

@Suite("StorageLocations")
struct StorageLocationsTests {
    @Test("injected root is used for the images directory")
    func injectedRootIsUsed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypo-storage-test-\(UUID().uuidString)")
        let locations = FixedStorageLocations(root: root)

        #expect(locations.imagesDirectory.path.hasPrefix(root.path))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos && swift test --filter StorageLocationsTests 2>&1 | tail -10
```

期望：编译失败，`cannot find 'FixedStorageLocations' in scope`。

- [ ] **Step 3: 定义协议与两个实现**

创建 `shared/HypoCore/Sources/HypoCore/Platform/StorageLocations.swift`：

```swift
import Foundation

/// Where the core writes blobs (images, received files).
///
/// macOS uses the user caches directory. iOS must not: the system evicts
/// Caches under storage pressure, which would silently drop history images.
/// iOS injects an App Group container path instead.
public protocol StorageLocations: Sendable {
    var imagesDirectory: URL { get }
}

/// Default macOS behavior: `~/Library/Caches/com.hypo.clipboard/images/`.
public struct CachesStorageLocations: StorageLocations {
    public init() {}

    public var imagesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("com.hypo.clipboard")
            .appendingPathComponent("images")
    }
}

/// Explicit root, used by tests and by the iOS App Group container.
public struct FixedStorageLocations: StorageLocations {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var imagesDirectory: URL {
        root.appendingPathComponent("images")
    }
}
```

- [ ] **Step 4: 移动存储文件并接入协议**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/History
git mv macos/Sources/HypoApp/Services/StorageManager.swift shared/HypoCore/Sources/HypoCore/History/StorageManager.swift
git mv macos/Sources/HypoApp/Services/OptimizedHistoryStore.swift shared/HypoCore/Sources/HypoCore/History/OptimizedHistoryStore.swift
```

在 `StorageManager.swift` 中，把第 23 行附近计算 `caches` 与 `imagesDirectory` 的代码替换为注入：

```swift
    private let locations: StorageLocations

    public init(locations: StorageLocations = CachesStorageLocations()) {
        self.locations = locations
        do {
            try FileManager.default.createDirectory(at: locations.imagesDirectory, withIntermediateDirectories: true)
        } catch {
            #if canImport(os)
            logger.error("Failed to create images directory: \(error.localizedDescription)")
            #endif
        }
    }
```

并把文件内其余引用 `imagesDirectory` 的地方改为 `locations.imagesDirectory`。默认参数 `CachesStorageLocations()` 保证 macOS 行为不变。

- [ ] **Step 5: 运行测试确认通过**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，新增 `StorageLocationsTests` 通过。

- [ ] **Step 6: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor(core): move storage layer behind StorageLocations protocol"
```

---

## Task 11: 拆分 HistoryStore.swift

`macos/Sources/HypoApp/Services/HistoryStore.swift` 有 1187 行两个职责：第 24~218 行是 `public actor HistoryStore`（纯持久化），第 219~1187 行是 `ClipboardHistoryViewModel`（macOS UI，依赖 `KeyboardShortcut`、`ClipboardMonitorDelegate`、`NSPasteboard`、`TempFileManager`）。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/History/HistoryStore.swift`（actor 部分）
- Create: `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift`（ViewModel 部分）
- Delete: `macos/Sources/HypoApp/Services/HistoryStore.swift`

- [ ] **Step 1: 拆出 actor 部分到 HypoCore**

把原文件第 1~218 行（含顶部 import 与第 22 行的 `extension UserDefaults: @retroactive @unchecked Sendable {}`）写入 `shared/HypoCore/Sources/HypoCore/History/HistoryStore.swift`。从中删除 `#if canImport(AppKit) import AppKit #endif` 整段——actor 部分不使用任何 `NS*` 类型。

- [ ] **Step 2: 拆出 ViewModel 部分到 HypoApp**

把原文件第 219 行到结尾写入 `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift`，顶部补上该段实际用到的 import：

```swift
import Foundation
import CryptoKit
#if canImport(Combine)
import Combine
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os.log
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
```

- [ ] **Step 3: 删除原文件**

```bash
git rm macos/Sources/HypoApp/Services/HistoryStore.swift
```

- [ ] **Step 4: 解绑通知控制器默认参数**

原第 272 行把协议默认值绑到了具体类型：

```swift
        notificationController: ClipboardNotificationScheduling? = ClipboardNotificationController.shared
```

`ClipboardNotificationController` 留在 `HypoApp`，而该默认值现在位于 `ClipboardHistoryViewModel.swift`（同在 `HypoApp`），因此**此处保持原样即可**，不需要修改。

- [ ] **Step 5: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `HistoryStoreTests`。若 `HistoryStoreTests` 同时覆盖 actor 与 ViewModel，保持它留在 `HypoAppTests` 不动——Task 15 才决定测试归属。

- [ ] **Step 6: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor(core): split HistoryStore actor from ClipboardHistoryViewModel"
```

---

## Task 12: 抽出 HistoryPersistence 协议

`HistoryStore` actor 直接持有 `UserDefaults`。iOS 上三个进程并发写历史，`UserDefaults` 的 App Group suite 跨进程不可靠（spec §7.2），因此持久化必须可替换。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/Platform/HistoryPersistence.swift`
- Modify: `shared/HypoCore/Sources/HypoCore/History/HistoryStore.swift`
- Test: `macos/Tests/HypoAppTests/HistoryPersistenceTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `macos/Tests/HypoAppTests/HistoryPersistenceTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoApp

@Suite("HistoryPersistence")
struct HistoryPersistenceTests {
    @Test("in-memory persistence round-trips data by key")
    func inMemoryRoundTrip() throws {
        let persistence = InMemoryHistoryPersistence()
        let payload = Data("hello".utf8)

        try persistence.setData(payload, forKey: "entries")

        #expect(try persistence.data(forKey: "entries") == payload)
    }

    @Test("reading an unwritten key returns nil")
    func readBeforeWriteIsNil() throws {
        let persistence = InMemoryHistoryPersistence()

        #expect(try persistence.data(forKey: "entries") == nil)
    }

    @Test("removing a key clears it")
    func removeClearsKey() throws {
        let persistence = InMemoryHistoryPersistence()
        try persistence.setData(Data("x".utf8), forKey: "entries")

        try persistence.removeValue(forKey: "entries")

        #expect(try persistence.data(forKey: "entries") == nil)
    }

    @Test("bool flags default to false and round-trip")
    func boolFlagRoundTrip() {
        let persistence = InMemoryHistoryPersistence()

        #expect(persistence.bool(forKey: "migrated") == false)

        persistence.setBool(true, forKey: "migrated")

        #expect(persistence.bool(forKey: "migrated") == true)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos && swift test --filter HistoryPersistenceTests 2>&1 | tail -10
```

期望：编译失败，`cannot find 'InMemoryHistoryPersistence' in scope`。

- [ ] **Step 3: 定义协议与两个实现**

创建 `shared/HypoCore/Sources/HypoCore/Platform/HistoryPersistence.swift`：

```swift
import Foundation

/// Key-value store backing the clipboard history.
///
/// The shape mirrors exactly what `HistoryStore` already asks of
/// UserDefaults: a Data blob for the entries, a Bool flag for the file
/// storage migration, and removal of the entries key.
///
/// macOS keeps using UserDefaults. iOS cannot: the main app, the share
/// extension and the notification service extension all write history, and a
/// UserDefaults App Group suite does not reliably propagate writes across
/// processes. iOS injects a file-backed implementation guarded by
/// NSFileCoordinator instead.
public protocol HistoryPersistence: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data, forKey key: String) throws
    func removeValue(forKey key: String) throws
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
}

/// Default macOS behavior, backed by UserDefaults.
public struct UserDefaultsHistoryPersistence: HistoryPersistence {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) throws -> Data? {
        defaults.data(forKey: key)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }

    public func removeValue(forKey key: String) throws {
        defaults.removeObject(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Test double. Not used in production code.
public final class InMemoryHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var flags: [String: Bool] = [:]

    public init() {}

    public func data(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return blobs[key]
    }

    public func setData(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        blobs[key] = data
    }

    public func removeValue(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        blobs.removeValue(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flags[key] ?? false
    }

    public func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        flags[key] = value
    }
}
```

**键名保持在 `HistoryStore` 内不变**——协议只搬运存取动作，不搬运键名。`HistoryStore` 现有的两个键 `com.hypo.clipboard.history_entries`（entries blob）与 `com.hypo.clipboard.file_storage_migration_v2`（迁移标志）原样保留，用户历史不会因升级丢失。

- [ ] **Step 4: 让 HistoryStore 走协议**

在 `HistoryStore` actor 中，把 `private let defaults: UserDefaults` 替换为 `private let persistence: HistoryPersistence`，初始化器改为：

```swift
    public init(maxEntries: Int = 200, persistence: HistoryPersistence = UserDefaultsHistoryPersistence()) {
        self.maxEntries = max(1, maxEntries)
        self.persistence = persistence
    }
```

四处调用点逐一替换（键名不动）：

| 原调用 | 替换为 |
|---|---|
| `defaults.data(forKey: Self.entriesKey)` | `try persistence.data(forKey: Self.entriesKey)` |
| `defaults.set(data, forKey: Self.entriesKey)` | `try persistence.setData(data, forKey: Self.entriesKey)` |
| `defaults.removeObject(forKey: Self.entriesKey)` | `try persistence.removeValue(forKey: Self.entriesKey)` |
| `defaults.bool(forKey: Self.fileStorageMigrationKey)` | `persistence.bool(forKey: Self.fileStorageMigrationKey)` |
| `defaults.set(true, forKey: Self.fileStorageMigrationKey)` | `persistence.setBool(true, forKey: Self.fileStorageMigrationKey)` |

若某个调用点所在方法原先不是 `throws`，用 `try?` 保持原有的静默失败语义，不要改变方法签名。

保留一个兼容初始化器，使现有调用点与测试不必改动：

```swift
    public init(maxEntries: Int = 200, defaults: UserDefaults) {
        self.init(maxEntries: maxEntries, persistence: UserDefaultsHistoryPersistence(defaults: defaults))
    }
```

- [ ] **Step 5: 运行测试确认通过**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `HistoryStoreTests` 与新增的 `HistoryPersistenceTests`。

- [ ] **Step 6: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor(core): put history behind a HistoryPersistence protocol"
```

---

## Task 13: 迁移同步引擎与临时文件管理

**Files:**
- Move: `macos/Sources/HypoApp/Services/SyncEngine.swift` → `shared/HypoCore/Sources/HypoCore/Sync/SyncEngine.swift`
- Move: `macos/Sources/HypoApp/Services/ClipboardEventDispatcher.swift` → `shared/HypoCore/Sources/HypoCore/Sync/ClipboardEventDispatcher.swift`
- Move: `macos/Sources/HypoApp/Services/TempFileManager.swift` → `shared/HypoCore/Sources/HypoCore/Files/TempFileManager.swift`

`TempFileManager` 必须迁移：它被 `TransportManager.swift:138` 与 `IncomingClipboardHandler.swift:216` 真实调用，两者都进 core。它的 AppKit 用法已被 `#if canImport(AppKit)` 守卫，iOS 上编译得过（只是没有剪贴板变化观察）。

- [ ] **Step 1: 移动文件**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/Sync shared/HypoCore/Sources/HypoCore/Files
git mv macos/Sources/HypoApp/Services/SyncEngine.swift shared/HypoCore/Sources/HypoCore/Sync/SyncEngine.swift
git mv macos/Sources/HypoApp/Services/ClipboardEventDispatcher.swift shared/HypoCore/Sources/HypoCore/Sync/ClipboardEventDispatcher.swift
git mv macos/Sources/HypoApp/Services/TempFileManager.swift shared/HypoCore/Sources/HypoCore/Files/TempFileManager.swift
```

- [ ] **Step 2: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `SyncEngineTests`、`ClipboardEventDispatcherTests`。

- [ ] **Step 3: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor(core): move sync engine and temp file manager into HypoCore"
```

---

## Task 14: 抽出 AppLifecycleObserving 并迁移 TransportManager

`TransportManager.swift` 内有私有类 `ApplicationLifecycleObserver`（被 `#if canImport(AppKit)` 守卫），监听 `NSApplication` 的 didBecomeActive / willResignActive / willTerminate。iOS 需要对应的 `UIApplication` 通知，因此提升为协议。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/Platform/AppLifecycleObserving.swift`
- Create: `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift`
- Create: `macos/Sources/HypoApp/Platform/AppKitLifecycleObserver.swift`
- Modify: `macos/Sources/HypoApp/Services/ClipboardNotificationController.swift`（删除协议声明）
- Move: `macos/Sources/HypoApp/Services/TransportManager.swift`、`ConnectionStatusProber.swift` → `shared/HypoCore/Sources/HypoCore/Transport/`
- Test: `macos/Tests/HypoAppTests/AppLifecycleObservingTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `macos/Tests/HypoAppTests/AppLifecycleObservingTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoApp

@Suite("AppLifecycleObserving")
struct AppLifecycleObservingTests {
    @Test("manual observer forwards each lifecycle event exactly once")
    func manualObserverForwardsEvents() {
        var activated = 0
        var deactivated = 0
        var terminated = 0

        let observer = ManualAppLifecycleObserver()
        observer.start(
            onActivate: { activated += 1 },
            onDeactivate: { deactivated += 1 },
            onTerminate: { terminated += 1 }
        )

        observer.simulateActivate()
        observer.simulateDeactivate()
        observer.simulateTerminate()

        #expect(activated == 1)
        #expect(deactivated == 1)
        #expect(terminated == 1)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos && swift test --filter AppLifecycleObservingTests 2>&1 | tail -10
```

期望：编译失败，`cannot find 'ManualAppLifecycleObserver' in scope`。

- [ ] **Step 3: 定义协议与测试替身**

创建 `shared/HypoCore/Sources/HypoCore/Platform/AppLifecycleObserving.swift`：

```swift
import Foundation

/// Observes host-application lifecycle transitions.
///
/// macOS listens to NSApplication notifications; iOS listens to
/// UIApplication ones. The core only needs the three transitions below.
public protocol AppLifecycleObserving: AnyObject {
    func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    )
    func stop()
}

/// Test double: events are driven explicitly rather than by the system.
public final class ManualAppLifecycleObserver: AppLifecycleObserving {
    private var onActivate: (@Sendable () -> Void)?
    private var onDeactivate: (@Sendable () -> Void)?
    private var onTerminate: (@Sendable () -> Void)?

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onTerminate = onTerminate
    }

    public func stop() {
        onActivate = nil
        onDeactivate = nil
        onTerminate = nil
    }

    public func simulateActivate() { onActivate?() }
    public func simulateDeactivate() { onDeactivate?() }
    public func simulateTerminate() { onTerminate?() }
}
```

- [ ] **Step 4: 提取通知调度协议**

创建 `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift`，把 `macos/Sources/HypoApp/Services/ClipboardNotificationController.swift:19` 处的 `public protocol ClipboardNotificationScheduling: AnyObject, Sendable { ... }` **整段声明**原样搬过来（方法签名不改），并从 `ClipboardNotificationController.swift` 中删除该声明，保留 `ClipboardNotificationHandling` 协议与具体类不动。

- [ ] **Step 5: 写 macOS 实现**

创建 `macos/Sources/HypoApp/Platform/AppKitLifecycleObserver.swift`：

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// macOS implementation of AppLifecycleObserving, replacing the private
/// ApplicationLifecycleObserver that used to live inside TransportManager.
public final class AppKitLifecycleObserver: AppLifecycleObserving {
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        #if canImport(AppKit)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            onActivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            onDeactivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            onTerminate()
        })
        #endif
    }

    public func stop() {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 6: 迁移 TransportManager 与 ConnectionStatusProber**

```bash
git mv macos/Sources/HypoApp/Services/TransportManager.swift shared/HypoCore/Sources/HypoCore/Transport/TransportManager.swift
git mv macos/Sources/HypoApp/Services/ConnectionStatusProber.swift shared/HypoCore/Sources/HypoCore/Transport/ConnectionStatusProber.swift
```

在 `TransportManager.swift` 中：删除文件末尾 `#if canImport(AppKit) private final class ApplicationLifecycleObserver { ... } #endif` 整段；把持有它的属性改为 `private let lifecycleObserver: AppLifecycleObserving?`；构造该观察者的地方改为调用注入实例的 `start(onActivate:onDeactivate:onTerminate:)`，闭包体保持原样。

初始化器增加参数，默认 `nil` 以保持现有调用点不变：

```swift
        lifecycleObserver: AppLifecycleObserving? = nil,
```

在 `macos/Sources/HypoApp/App/AppContext.swift` 构造 `TransportManager` 的地方传入 `lifecycleObserver: AppKitLifecycleObserver()`，保证 macOS 行为不变。

同时把 `TransportManager.swift:116` 的默认参数

```swift
        notificationController: ClipboardNotificationScheduling = ClipboardNotificationController.shared,
```

改为无默认值（`notificationController: ClipboardNotificationScheduling,`），并在 `AppContext.swift` 的构造点显式传入 `ClipboardNotificationController.shared`。

- [ ] **Step 7: 运行测试确认通过**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `TransportManagerTests`、`TransportManagerLanTests` 与新增的 `AppLifecycleObservingTests`。

- [ ] **Step 8: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "refactor(core): move TransportManager behind AppLifecycleObserving"
```

---

## Task 15: 抽出 ClipboardWriting 并迁移 IncomingClipboardHandler

`IncomingClipboardHandler.swift:2` 是全包唯一的裸 `import AppKit`，且直接使用 `NSPasteboard` 与 `NSImage`（读 `types`/`string(forType:)`/`readObjects`，写 `clearContents`/`setString`/`writeObjects`）。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/Platform/ClipboardWriting.swift`
- Create: `macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift`
- Move: `macos/Sources/HypoApp/Services/IncomingClipboardHandler.swift` → `shared/HypoCore/Sources/HypoCore/Sync/IncomingClipboardHandler.swift`
- Test: `macos/Tests/HypoAppTests/ClipboardWritingTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `macos/Tests/HypoAppTests/ClipboardWritingTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoApp

@Suite("ClipboardWriting")
struct ClipboardWritingTests {
    @Test("recording writer captures text writes in order")
    @MainActor
    func recordingWriterCapturesText() {
        let writer = RecordingClipboardWriter()

        writer.clear()
        writer.writeText("first")
        writer.writeText("second")

        #expect(writer.currentText() == "second")
        #expect(writer.writtenTexts == ["first", "second"])
    }

    @Test("clear resets the recorded text")
    @MainActor
    func clearResetsText() {
        let writer = RecordingClipboardWriter()

        writer.writeText("value")
        writer.clear()

        #expect(writer.currentText() == nil)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos && swift test --filter ClipboardWritingTests 2>&1 | tail -10
```

期望：编译失败，`cannot find 'RecordingClipboardWriter' in scope`。

- [ ] **Step 3: 定义协议与测试替身**

创建 `shared/HypoCore/Sources/HypoCore/Platform/ClipboardWriting.swift`：

```swift
import Foundation

/// System clipboard access needed by the core.
///
/// Covers exactly what IncomingClipboardHandler used to do directly against
/// NSPasteboard: compare against current contents, then apply the payload.
@MainActor
public protocol ClipboardWriting: AnyObject {
    func clear()
    func writeText(_ text: String)
    /// Returns false when the data cannot be decoded as an image on this platform.
    func writeImageData(_ data: Data) -> Bool
    func writeFileURL(_ url: URL)
    func currentText() -> String?
    func containsImage() -> Bool
}

/// Test double recording every write.
@MainActor
public final class RecordingClipboardWriter: ClipboardWriting {
    public private(set) var writtenTexts: [String] = []
    public private(set) var writtenImageData: [Data] = []
    public private(set) var writtenFileURLs: [URL] = []
    private var text: String?
    private var hasImage = false

    public init() {}

    public func clear() {
        text = nil
        hasImage = false
    }

    public func writeText(_ value: String) {
        text = value
        writtenTexts.append(value)
    }

    public func writeImageData(_ data: Data) -> Bool {
        writtenImageData.append(data)
        hasImage = true
        return true
    }

    public func writeFileURL(_ url: URL) {
        writtenFileURLs.append(url)
    }

    public func currentText() -> String? { text }

    public func containsImage() -> Bool { hasImage }
}
```

- [ ] **Step 4: 写 macOS 实现**

创建 `macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift`：

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// macOS implementation of ClipboardWriting, backed by NSPasteboard.
@MainActor
public final class AppKitClipboardWriter: ClipboardWriting {
    #if canImport(AppKit)
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func clear() {
        pasteboard.clearContents()
    }

    public func writeText(_ text: String) {
        pasteboard.setString(text, forType: .string)
    }

    public func writeImageData(_ data: Data) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        pasteboard.writeObjects([image])
        return true
    }

    public func writeFileURL(_ url: URL) {
        pasteboard.writeObjects([url as NSURL])
    }

    public func currentText() -> String? {
        guard let types = pasteboard.types, types.contains(.string) else { return nil }
        return pasteboard.string(forType: .string)
    }

    public func containsImage() -> Bool {
        !pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
            .compactMap { $0 as? NSImage }
            .isEmpty
    }
    #endif
}
```

- [ ] **Step 5: 迁移 handler 并改用协议**

```bash
git mv macos/Sources/HypoApp/Services/IncomingClipboardHandler.swift shared/HypoCore/Sources/HypoCore/Sync/IncomingClipboardHandler.swift
```

在该文件中：删除第 2 行裸 `import AppKit`；把 `private let pasteboard: NSPasteboard` 改为 `private let clipboard: ClipboardWriting`；初始化器参数 `pasteboard: NSPasteboard = .general` 改为 `clipboard: ClipboardWriting`（无默认值）。

`matchesCurrentClipboard` 中：`.text` 与 `.link` 分支改用 `clipboard.currentText()`；`.image` 分支改用 `clipboard.containsImage()`（原逻辑在有图时仍返回 `false`，保持不变）。

`applyToClipboard` 中：`pasteboard.clearContents()` → `clipboard.clear()`；`setString(_:forType: .string)` → `clipboard.writeText(_:)`；`.image` 分支的 `NSImage(data:)` + `writeObjects` 改为：

```swift
        case .image:
            guard clipboard.writeImageData(payload.data) else {
                throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from data"])
            }
```

`.file` 分支写临时文件的逻辑不变，最后把文件 URL 交给 `clipboard.writeFileURL(tempURL)`。

在 `macos/Sources/HypoApp/App/AppContext.swift` 构造 `IncomingClipboardHandler` 的地方传入 `clipboard: AppKitClipboardWriter()`。

- [ ] **Step 6: 运行测试确认通过**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿，含 `IncomingClipboardHandlerTests` 与新增的 `ClipboardWritingTests`。若 `IncomingClipboardHandlerTests` 里构造 handler 时传了 `pasteboard:`，改为传 `RecordingClipboardWriter()`，并把断言从检查 `NSPasteboard.general` 改为检查 `writer.writtenTexts` 等记录属性。

- [ ] **Step 7: 可移植性闸门 + CI iOS 验证**

```bash
cd shared/HypoCore && grep -rn "import AppKit\|NSPasteboard\|NSImage\|NSApplication\|NSWorkspace\|NSStatusItem\|NSColor\|NSEvent" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 8: 确认全包已无裸 AppKit import**

```bash
cd shared/HypoCore && grep -rn "^import AppKit" Sources/ ; echo "exit=$?"
```

期望：无输出，`exit=1`。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "refactor(core): move IncomingClipboardHandler behind ClipboardWriting"
```

---

## Task 16: 测试重定位与双平台运行

把纯 core 的测试移入 `HypoCore` 自己的测试目标，使它们在 iOS 上也能运行——这是 spec §10「跨平台一致性」的落点。

**Files:**
- Modify: `shared/HypoCore/Package.swift`
- Move: 14 个测试文件 `macos/Tests/HypoAppTests/` → `shared/HypoCore/Tests/HypoCoreTests/`

- [ ] **Step 1: 给 HypoCore 加测试目标**

在 `shared/HypoCore/Package.swift` 中加入依赖与测试目标：

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0")
    ],
```

并在 `targets` 数组末尾追加：

```swift
        .testTarget(
            name: "HypoCoreTests",
            dependencies: [
                "HypoCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoCoreTests"
        )
```

- [ ] **Step 2: 移动纯 core 测试**

```bash
mkdir -p shared/HypoCore/Tests/HypoCoreTests
cd macos/Tests/HypoAppTests
for f in CryptoServiceTests.swift TransportFrameCodecTests.swift TokenBucketTests.swift \
         WebSocketTransportTests.swift TransportMetricsAggregatorTests.swift \
         CloudRelayTransportTests.swift LanSyncTransportTests.swift \
         LanWebSocketTransportTests.swift LanWebSocketServerTests.swift \
         LanWebSocketServerBufferTests.swift BonjourBrowserTests.swift \
         BonjourPublisherTests.swift PairingSessionTests.swift SyncEngineTests.swift; do
  git mv "$f" "../../../shared/HypoCore/Tests/HypoCoreTests/$f"
done
```

**留在 `HypoAppTests` 的**：`ClipboardMonitorTests.swift`、`ShortcutConfigurationTests.swift`、`HistoryStoreTests.swift`、`IncomingClipboardHandlerTests.swift`、`ClipboardEventDispatcherTests.swift`、`TransportManagerTests.swift`、`TransportManagerLanTests.swift`、`MockSupport.swift`，以及本计划新增的 5 个测试文件。

**已实测的辅助类型依赖**（Task 2 的代码质量审查逐文件清点，不必重新推导）——14 个待迁文件中有 8 个引用了辅助类型：

| 待迁测试文件 | 依赖的辅助类型 | 定义位置 |
|---|---|---|
| `WebSocketTransportTests` | `StubSession`、`StubWebSocketTask`、`FlakyWebSocketTask`、`RecordingMetricsRecorder`、`MutableClock`、`Locked` | `MockSupport.swift:237/252/417/586/613`、`TestSupport.swift:46` |
| `CloudRelayTransportTests` | `StubSession`、`StubWebSocketTask`、`Locked` | 同上 |
| `LanWebSocketTransportTests` | `StubSession`、`StubWebSocketTask`、`FlakyWebSocketTask`、`RecordingMetricsRecorder`、`Locked` | 同上 |
| `LanWebSocketServerTests` | `UnfairLock` | `MockSupport.swift:8` |
| `LanWebSocketServerBufferTests` | `Locked` | `TestSupport.swift:46` |
| `BonjourBrowserTests` | `MockBonjourDriver`、`MutableClock` | `MockSupport.swift:39/613` |
| `BonjourPublisherTests` | `Locked` | `TestSupport.swift:46` |
| `PairingSessionTests` | `MutableClock`、`Locked` | `MockSupport.swift:613`、`TestSupport.swift:46` |

**因此把 `TestSupport.swift` 整体迁入 `HypoCoreTests`**，不要按类型逐个复制——该文件只 import `Foundation`、`Testing`、`os`，零 macOS 依赖，其中 `Locked` 被 6 个待迁文件引用。`MockSupport.swift` 留在 `HypoAppTests`（`TransportManagerTests` 等仍需要它），把上表中被待迁文件引用的类型复制进新建的 `shared/HypoCore/Tests/HypoCoreTests/CoreTestSupport.swift`。

- [ ] **Step 3: 修正被移动测试的 import**

移动后的每个文件把 `@testable import HypoApp` 改为 `@testable import HypoCore`：

```bash
cd shared/HypoCore/Tests/HypoCoreTests && sed -i '' 's/@testable import HypoApp/@testable import HypoCore/' *.swift
```

- [ ] **Step 4: 运行 HypoCore 测试（macOS）**

```bash
cd shared/HypoCore && swift test 2>&1 | tail -20
```

期望：全绿。若某个文件引用了留在 `HypoAppTests` 的 `MockSupport.swift` / `TestSupport.swift` 中的辅助类型，把**该辅助类型**复制进 `shared/HypoCore/Tests/HypoCoreTests/CoreTestSupport.swift`；若某个测试文件对 macOS 类型的依赖无法解开，把该文件移回 `macos/Tests/HypoAppTests/` 并在本计划此处记录原因。

- [ ] **Step 5: 把 iOS 模拟器测试加进 CI job**

本机跑不了模拟器测试，加到 Task 1B 建立的 job 里。在 `.github/workflows/ci.yml` 的 `ios-core-build` job 末尾追加一步：

```yaml
      - name: Run HypoCore tests on iOS Simulator
        working-directory: shared/HypoCore
        run: |
          xcodebuild test \
            -scheme HypoCore \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            -skipMacroValidation \
            -enableCodeCoverage NO
```

提交推送后确认该步骤通过：

```bash
gh run list --branch feat/ios-hypocore --limit 3
```

若 runner 上无 `iPhone 16` 机型，在该步骤前加一步 `xcrun simctl list devicetypes` 查看可用机型并替换 `name=`。

- [ ] **Step 6: 运行 HypoApp 测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：全绿。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "test(core): relocate core tests to HypoCore and run them on iOS"
```

---

## Task 17: 验证既有构建与 CI 未受影响

spec §2.2 的前提是 macOS 的构建、签名、CI 一律不动。这一任务专门证明这个前提成立。

**Files:**
- Read-only: `scripts/build-macos.sh`、`.github/workflows/ci.yml`

- [ ] **Step 1: 跑 macOS 调试构建**

```bash
./scripts/build-macos.sh
```

期望：脚本成功结束并产出 `macos/HypoApp.app`。脚本内部走 `swift build --package-path`（`build-macos.sh:216`），本地路径依赖会被自动解析，无需改脚本。

- [ ] **Step 2: 跑 macOS 发布构建**

```bash
./scripts/build-macos.sh release
```

期望：成功结束。

- [ ] **Step 3: 复核 CI 配置无需改动**

```bash
grep -n "xcodebuild" .github/workflows/ci.yml
```

现有 `macos-tests` job 在 `macos-15` runner 上跑 `xcodebuild test -scheme HypoApp-Package -destination 'platform=macOS'`，并且会先 `rm -rf HypoApp.xcworkspace`，因此直接使用 `Package.swift`。新增的本地路径依赖由 SwiftPM 自动解析，**该 job 无需任何修改**。

本任务只确认 `macos-tests`、`backend-tests`、`android-tests` 三个既有 job 未被改动；Task 1B 与 Task 16 新增的 `ios-core-build` 是有意添加，不算违反。

- [ ] **Step 4: 确认工作区干净**

```bash
git status --short
```

期望：无未提交改动（构建产物若被 `.gitignore` 覆盖则不出现；若出现新的构建产物路径，加入 `.gitignore` 并单独提交）。

- [ ] **Step 5: 最终验收——三条命令全绿**

```bash
cd macos && swift test 2>&1 | tail -5
cd shared/HypoCore && swift test 2>&1 | tail -5
gh run list --branch feat/ios-hypocore --limit 1
```

期望：前两条 `Test run with N tests passed`，两个目标的通过数之和不少于基线 193；第三条显示最近一次 CI 全绿，含 `HypoCore iOS Build`。

- [ ] **Step 6: 提交（若 Step 4 产生了 .gitignore 改动）**

```bash
git add .gitignore
git commit -m "chore: ignore HypoCore build artifacts"
```

---

## 第 1 期完成定义

1. `cd macos && swift test` 全绿；macOS 与 HypoCore 两个测试目标的通过数之和不少于基线 193
2. `cd shared/HypoCore && swift test` 全绿
3. CI 的 `ios-core-build` job 中 `Build HypoCore for iOS Simulator` 步骤成功（本机无 Xcode，这是唯一的权威验证）
4. CI 的 `ios-core-build` job 中 `Run HypoCore tests on iOS Simulator` 步骤成功
5. `./scripts/build-macos.sh` 与 `./scripts/build-macos.sh release` 均成功
6. `shared/HypoCore/Sources/` 下无裸 `import AppKit`
7. `scripts/` 下无任何改动；`.github/workflows/ci.yml` 的改动仅限于：新增 `ios-core-build` job、新增顶层 `concurrency` 块（Task 2 决策 2，`main` 上不生效）。三个既有 job 的 YAML 文本必须逐字节未变

达成后进入第 2 期（iOS 前台版），届时另写一份计划。
