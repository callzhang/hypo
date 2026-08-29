# HypoCore 抽取实现计划（iOS 第 1 期）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 macOS 客户端中与平台无关的逻辑抽成 `HypoCore` 跨平台 SwiftPM package，使其能同时为 macOS 与 iOS 构建，且 macOS 端行为与测试完全不变。

**Architecture:** 新建 `shared/HypoCore/` package（`platforms: [.macOS(.v13), .iOS(.v17)]`），`macos/Package.swift` 以本地路径依赖它。文件按依赖顺序自底向上分批 `git mv`，每批之后跑完整测试套件。三处 AppKit 耦合改为协议注入，macOS 实现留在 `HypoApp`。`Services/HistoryStore.swift` 按职责拆分：`HistoryStore` actor 进 core，`ClipboardHistoryViewModel` 留在 app。

**Tech Stack:** Swift 6 / SwiftPM (tools-version 6.0) / swift-testing 0.5.0 / Network.framework / CryptoKit

**参考文档:** `docs/superpowers/specs/2026-08-28-ios-app-design.md`（§2、§4）

---

## 关键约定

### worktree 的并发写入纪律（2026-08-29 事故后追加）

Task 4 期间同时有三个执行者在这个 worktree 里作业：修复实现者、spec 审查者、协调会话。审查者为了对比 HEAD 状态执行了 `git stash`，把实现者**未提交的工作**暂存掉了，导致后者看到自己的编辑凭空消失、随后又以旧版本重现，并合理地怀疑环境被篡改。工作最终没有丢失，但差一点。

**因此：**

1. **审查者必须严格只读。** 不得 `git stash`、`git checkout`、`git reset`，不得修改任何文件。要读某个提交的状态，用 `git show <sha>:<path>` 或 `git diff <sha>`，**不要动工作区**。
2. **同一时刻只允许一个写入者。** 派出实现者之后，在它提交完成之前不要派出任何会写入的 agent。审查可以并行，但必须是只读的。
3. **协调会话自己也算写入者。** 若要在 worktree 里直接改文件（例如插队做一个独立的小任务），先确认 `git status --short` 为空，即没有其它 agent 的未提交工作。
4. **实现者暂存时按路径列举，不要 `git add -A`。** 避免把别人的改动扫进自己的提交。



**每个任务结束时测试必须全绿。** 验证命令固定为：

```bash
cd macos && swift test 2>&1 | tail -20
```

期望输出结尾包含 `Test run with N tests passed`，且 N ≥ 193。

**本机没有 Xcode。** `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，`/Applications` 下无 `Xcode.app`，因此**没有 iOS SDK、没有模拟器、`xcodebuild` 不可用**。SwiftPM 也无法绕过：交叉编译到 iOS 需要随 Xcode 分发的 iOS SDK。

因此 iOS 验证分成两层：

**本地可移植性闸门**（每个搬迁任务都要跑）：

```bash
cd shared/HypoCore && find Sources -name '*.swift' | while read f; do awk -v F="$f" '
  /^[[:space:]]*#if canImport\(AppKit\)/ { d++; next }
  d>0 && /^[[:space:]]*#endif/ { d--; next }
  d==0 { print F":"FNR": "$0 }
' "$f"; done | grep -E "import AppKit|NSPasteboard|NSImage|NSApplication|NSWorkspace|NSStatusItem|NSColor|NSEvent|NSWindow|NSMenu|NSAlert|NSViewController|NSCursor" | grep -vE ': *(///|//|\*)' ; echo "exit=$?"
```

期望：无输出，`exit=1`。这不能证明 iOS 构建成功，但能在本地立刻抓住最可能的破坏源——把 macOS 专有类型带进了 core。

**CI 上的权威验证**：Task 1B 新增的 `ios-core-build` job 在 `macos-15` runner 上跑真正的 `xcodebuild`。**每个任务提交后都要推送并确认该 job 通过**，不要攒着一次推。

**本地闸门抓不到 macOS-only 的无前缀 Foundation 类型**（Task 4 实测，CI 首次拦下真实缺陷）：`DeviceIdentity.swift:38` 的默认参数用了 `Host.current().localizedName`。`Host` 是 macOS 独有的 Foundation 类型（`NSHost` 的 Swift 名），**名字不带 `NS` 前缀，闸门的 grep 抓不到；在 macOS 上编译测试全过，只有真正用 iOS SDK 编译才报 `cannot find 'Host' in scope`**。

已扫描全代码库，同类 API 只有两处：这一处，以及 `ClipboardNotificationController.swift:412` 的 `NSWorkspace`（留在 HypoApp，不迁移）。**因此后续批次无需再担心此类问题**，但结论要记住：**CI 的 iOS 构建是唯一能发现这类缺陷的环节，绝不能因为本地三道闸门全绿就跳过等待 CI**。

**闸门必须理解条件编译**（Task 5 实测）：`TempFileManager.swift` 里有 `import AppKit`、`NSPasteboard` 属性和一个 AppKit 专用初始化器，但**全部包在 `#if canImport(AppKit)` 内**——`AppKit` 在 iOS 上不存在，整段编译不进去，代码完全正确。旧闸门只过滤注释行，于是报了三条误报。

上面的闸门命令已改为先用 awk 剥离 `#if canImport(AppKit) ... #endif` 块再匹配。实测：旧写法报 3 条，新写法干净退出。

两点局限，使用时心里有数：块内的 `#else` 分支（即非 AppKit 路径）也会被一并跳过——按定义那里不会有 AppKit 符号，可接受；嵌套的 `#if` 会让深度计数提前归零——本代码库暂无此情况，若将来出现，闸门可能漏报，届时以 CI 的 iOS 构建为准。

**闸门是线索来源，不是判决**。命中不等于有错，先看是否落在守卫块内；干净也不等于安全（`Host` 那次就是干净的）。唯一的权威结论来自 CI 的 `ios-core-build`。

**闸门的两个已知陷阱**（Task 4 实测）：

1. **注释误报**。闸门是纯文本匹配，一句「useful for NSImage/Preview」的文档注释就会让它变红（`StorageManager.swift:82` 即是），而该文件根本没有 `import AppKit`。因此闸门命令已加上 `| grep -vE ':[0-9]+: *(///|//|\*)'` 过滤纯注释行。**会误报的闸门很快就没人看，比没有闸门更危险**——若仍出现命中，先确认是真的代码引用再动手。

2. **`swift build` 通过不等于没问题**。Task 4 需要改 `public` 的两个符号里，`TokenBucket.consume()` 被 app 代码引用（build 阶段就报错），但 `TokenBucket.init` 只被**测试代码**直接构造（`TokenBucketTests.swift`、`ClipboardMonitorTests.swift` 共 26 处），**只有 `swift test` 会暴露**。搬迁后必须跑完整测试套件，不能停在 build 成功。

**闸门与 CI 覆盖不到什么**（Task 3 质量审查结论，务必先读再动 Task 5/6/10）：

本地 grep 闸门只能抓**编译期**的 AppKit 符号泄漏；CI 的 `ios-core-build` 跑的是 `xcodebuild build`，**只证明能编译，不启动模拟器、不执行测试**。以下三类问题「编译通过 + CI 全绿」却会在真机上静默失效，必须靠人工复核，不要因为闸门是绿的就认为安全：

- **Task 5 Keychain**：`KeychainKeyStore` 对两端构造相同的 `SecItemAdd`/`SecItemCopyMatching` 查询，但语义不同——macOS 默认使用旧的文件式 keychain，除非设置 `kSecUseDataProtectionKeychain`（iOS 只有 data-protection keychain）；`accessGroup` 在 iOS 上还需要对应 entitlement 才生效。搬迁时**不要**顺手改这些，但要在提交信息里记下这个待办，留给第 2/3 期处理。
- **Task 6 Bonjour**：`NetService`/`NetServiceBrowser` 在 iOS 编译无碍，但 iOS 14+ 缺少 `NSLocalNetworkUsageDescription` 与 `NSBonjourServices` 会导致发现静默失败。这是 Info.plist 的职责，SwiftPM library target 承载不了，属于第 2 期 iOS App 外壳的工作。
- **Task 10 存储路径**：`UserDefaults` 与 `FileManager` 在 iOS 上都存在，但 `NSHomeDirectory()`、`~/Library`、非沙盒路径拼接会解析到错误位置或直接失败。搬迁时额外跑一遍这个**人工复核用**的 grep（不作为通过/失败判据，只是把可疑点摊开来看）：

```bash
cd shared/HypoCore && grep -rn "NSHomeDirectory\|homeDirectoryForCurrentUser\|/Users/\|~/Library\|UserDefaults(suiteName:" Sources/
```

**`@_exported` 的作用范围（澄清，勿误信相反说法）**：`macos/Sources/HypoApp/HypoCoreExport.swift` 里的 `@_exported import HypoCore` 使 HypoCore 的 public 符号在**整个 HypoApp 模块**可见，而不只是那一个文件。这正是「exported」的含义。

**因此留在 HypoApp 的文件永远不需要新增 `import HypoCore`**，无论它们引用的类型搬走了多少。直接反证：批次 1–3 共搬了 24 个文件，零个消费方文件需要加 import。若有人提出「某文件在依赖搬走后需要显式 import」，那是误解——真正会断的是**可见性**（internal 符号跨模块不可见），不是 import。

**`@testable import HypoCore` 可从 `HypoAppTests` 触及 HypoCore 的 internal 符号**（Task 10 实测确认）。SwiftPM 在 debug 下对所有 target 启用 `-enable-testing`，因此测试目标可以 `@testable` 导入其依赖链上的任意模块，而不只是直接被测模块。

这条实测结论解决了 Task 10 的最后一个障碍。搬迁后有 8 个 internal 符号（`WebSocketTransport.handleOpen`/`QueuedMessage`/`messageQueue`/`inFlightMessages`、`CloudRelayTransport.handleOpen`/`underlying`、`LanWebSocketTransport.handleOpen`、`LanSyncTransport.normalizedPeers`）被留在 `HypoAppTests` 的测试触及。三条路：

1. 改成 `public` —— **错**。这些是实现细节，为测试而公开会永久污染 API 面。
2. 把四个测试文件移进 `HypoCoreTests` —— 正确但代价大：`MutableClock` 被 3 个留守测试使用，`TestSupport.swift` 的内容被 10 个文件使用，都要跨模块复制。
3. **给那四个测试文件各加一行 `@testable import HypoCore`** —— 四行解决，零 API 污染，零文件搬迁。已采用。

**因此 Task 12 的目的变了**：不再是「让测试能编译」，而是「让 core 的测试能在 iOS 模拟器上运行」——即 spec §10 要求的跨平台一致性验证。搬迁测试文件仍然值得做，但理由是覆盖面而非编译需要。

**跨模块可见性的三类盲区**（Task 3、5、6 各栽一次，按隐蔽程度排序）：

1. **合成的 memberwise init 永远是 internal**，与属性访问级别无关。Task 6 的 `PairingChallengePayload` 所有存储属性都是 `public`，却没有显式 `public init`，而 `PairingSessionTests.swift`（留在 `HypoAppTests`）直接构造它。**`swift build` 完全看不到——只有 `swift test` 会炸**，因为只有测试代码构造它。搬迁前对每个 `public struct` 确认：它有显式 `public init` 吗？如果没有，谁在构造它？

2. **扩展在内置类型上**（`Int`、`String`、`Data`、`URL`、`CodingUserInfoKey`）。审计"这个文件的公开 API"时，人和模型都只看自己定义的 type，扩展在系统类型上的成员不属于任何本地 type，因而被跳过。Task 3 的 `Int.formattedAsKB`、Task 5 的 `CodingUserInfoKey.skipLargeData` 都是这么漏的。**注意：仅仅 grep 出扩展是不够的**——Task 5 的实现者 grep 到了那个扩展，但没逐个看成员，还是漏了。

3. **扩展在已迁移类型上、但成员被留守文件使用**。Task 6 的 `extension ClipboardEntry { estimatedMemoryFootprint }` 定义在 `OptimizedHistoryStore.swift` 里，被留在 HypoApp 的 `MemoryProfiler.swift` 使用。类型本身是 public 不代表扩展成员是。

**已知的死代码**：`OptimizedHistoryStore`（一个 actor）在全仓库无任何构造点——只有 `MemoryProfiler.swift:284` 一句注释提到它。已随批次 3 迁入 HypoCore。Task 8 拆分 `HistoryStore.swift` 时会与它相邻，**不要顺手删**，与其它清理一样另起提交。

**跨模块可见性的旧盲区说明**（Task 3 实测结论）：这个代码库的自定义类型基本已经标好 `public`，Task 3 搬的四个文件里三个完全不用改。唯一漏网的是 **`Int.formattedAsKB`——一个对内置类型的扩展**。审计一个文件的「公开 API 面」时，人和模型都倾向于只看自己定义的 type，扩展在 `Int`/`String`/`Data`/`URL` 等系统类型上的成员最容易漏。**每次搬迁前先 `grep -n "^extension \|^public extension " <file>` 过一遍**，比等编译器报错再回头改快。

**基线**：抽取开始前 `cd macos && swift test` 的结果是 `✔ Test run with 193 tests passed after 5.699 seconds.`（2026-08-28 实测）。任务过程中通过数只应增加，不应减少。

**为什么 package 放在 `shared/HypoCore/` 而不是 `shared/`**：SwiftPM 对本地路径依赖使用目录名作为 package identity。放在 `shared/` 会得到 identity `shared`，产品引用要写成 `.product(name: "HypoCore", package: "shared")`，易错。放在 `shared/HypoCore/` 则 identity 与 package 名一致。第 5 期的 `HypoUI` 将来放 `shared/HypoUI/`。

**关于 `unsafeFlags`**：`macos/Package.swift` 现有的 `.unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"], .when(platforms: [.macOS]))` **不要复制到 HypoCore**。tools-version 6.0 的 target 默认就是 Swift 6 语言模式，严格并发检查已默认开启；且带 `unsafeFlags` 的 package 无法被版本化依赖引用，会给将来留坑。

---

## 文件结构

### 新建

| 路径 | 职责 |
|---|---|
| `shared/HypoCore/Package.swift` | package 定义，双平台声明 |
| `shared/HypoCore/Sources/HypoCore/Platform/SystemClipboard.swift` | 剪贴板写入协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/AppLifecycleObserving.swift` | 应用生命周期观察协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/HistoryPersistence.swift` | 历史持久化协议 |
| `shared/HypoCore/Sources/HypoCore/Platform/StorageLocations.swift` | 存储目录协议 |
| `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift` | 从具体控制器中提取的协议声明 |
| `shared/HypoCore/Tests/HypoCoreTests/` | Task 15 迁入的 core 测试 |
| `macos/Sources/HypoApp/HypoCoreExport.swift` | `@_exported import HypoCore`，使 app 与测试代码无需逐文件加 import |
| `macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift` | `SystemClipboard` 的 macOS 实现 |
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

spec §4.2 列了 4 个平台适配协议，本计划只建 3 个（`SystemClipboard`、`AppLifecycleObserving`、`StorageLocations`、`HistoryPersistence` 中的后三个加第一个，共 4 个文件），**唯独不建 `ClipboardMonitoring`**。

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
cd shared/HypoCore && find Sources -name '*.swift' | while read f; do awk -v F="$f" '
  /^[[:space:]]*#if canImport\(AppKit\)/ { d++; next }
  d>0 && /^[[:space:]]*#endif/ { d--; next }
  d==0 { print F":"FNR": "$0 }
' "$f"; done | grep -E "import AppKit|NSPasteboard|NSImage|NSApplication|NSWorkspace|NSStatusItem|NSColor|NSEvent|NSWindow|NSMenu|NSAlert|NSViewController|NSCursor" | grep -vE ': *(///|//|\*)' ; echo "exit=$?"
```

期望：无输出，`exit=1`。随后推送本任务的提交，确认 CI 的 `ios-core-build` job 通过——那才是 iOS 构建的权威结论。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor(core): move utility layer into HypoCore"
```

---

## 计划修订（2026-08-29）：搬迁顺序按实测依赖图重排

Task 4 首次尝试搬 Models 时暴露了原计划的一个结构性错误：`ClipboardEntry.swift` 调用 `StorageManager.shared.load(...)`，`PairedDevice.swift` 的 `init(from peer: DiscoveredPeer)` 依赖 `BonjourBrowser.swift` 里的类型，两者都排在更后面的任务，所以纯 `git mv` 编译不过。

据此对全部 36 个待迁文件做了依赖图实测，结论：

- **20 个文件**存在有效拓扑序，可分 4 批增量搬迁。
- **16 个文件构成一个不可分割的循环依赖簇**（传输 / 同步 / 历史核心）。典型环：`TransportFrameCodec ↔ SyncEngine`、`TransportManager ↔ TransportAnalytics ↔ TransportMetricsRecorder`、`WebSocketTransport ↔ HistoryStore`。这类环无法靠排序消除，**必须一次性搬完**。

为了让那个大提交仍然可审，把内容改动与文件移动彻底分离：先在 HypoApp 原地完成拆分与协议抽取（Task 8、9），使那 16 个文件不再引用留在 App 的类型，然后 Task 10 就是一个纯 rename 提交。

**每个搬迁任务的实现者都必须在 `git mv` 之后、写任何测试之前先跑 `cd macos && swift build`**——Task 4 的实现者正是这样才提前发现问题，而不是照着计划一路走到底。

---

## Task 4: 搬迁批次 1（7 个无前置依赖的文件）

**Files（全部 `git mv`，零内容改动）:**

| 源 | 目标 |
|---|---|
| `macos/Sources/HypoApp/Services/DeviceIdentity.swift` | `shared/HypoCore/Sources/HypoCore/Models/DeviceIdentity.swift` |
| `macos/Sources/HypoApp/Services/ClipboardEventDispatcher.swift` | `shared/HypoCore/Sources/HypoCore/Sync/ClipboardEventDispatcher.swift` |
| `macos/Sources/HypoApp/Services/PairingRelayClient.swift` | `shared/HypoCore/Sources/HypoCore/Pairing/PairingRelayClient.swift` |
| `macos/Sources/HypoApp/Services/RateLimiter.swift` | `shared/HypoCore/Sources/HypoCore/Transport/RateLimiter.swift` |
| `macos/Sources/HypoApp/Services/StorageManager.swift` | `shared/HypoCore/Sources/HypoCore/History/StorageManager.swift` |
| `macos/Sources/HypoApp/Services/WebSocketConnectionPool.swift` | `shared/HypoCore/Sources/HypoCore/Transport/WebSocketConnectionPool.swift` |
| `macos/Sources/HypoApp/Utilities/BonjourBrowser.swift` | `shared/HypoCore/Sources/HypoCore/Discovery/BonjourBrowser.swift` |

- [ ] **Step 1: 建目录并移动**

```bash
cd /Users/derek/Documents/Projects/hypo/.worktrees/ios-hypocore
mkdir -p shared/HypoCore/Sources/HypoCore/{Models,Sync,Pairing,Transport,History,Discovery}
git mv macos/Sources/HypoApp/Services/DeviceIdentity.swift shared/HypoCore/Sources/HypoCore/Models/DeviceIdentity.swift
git mv macos/Sources/HypoApp/Services/ClipboardEventDispatcher.swift shared/HypoCore/Sources/HypoCore/Sync/ClipboardEventDispatcher.swift
git mv macos/Sources/HypoApp/Services/PairingRelayClient.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingRelayClient.swift
git mv macos/Sources/HypoApp/Services/RateLimiter.swift shared/HypoCore/Sources/HypoCore/Transport/RateLimiter.swift
git mv macos/Sources/HypoApp/Services/StorageManager.swift shared/HypoCore/Sources/HypoCore/History/StorageManager.swift
git mv macos/Sources/HypoApp/Services/WebSocketConnectionPool.swift shared/HypoCore/Sources/HypoCore/Transport/WebSocketConnectionPool.swift
git mv macos/Sources/HypoApp/Utilities/BonjourBrowser.swift shared/HypoCore/Sources/HypoCore/Discovery/BonjourBrowser.swift
```

- [ ] **Step 2: 立刻构建，确认边界成立**

```bash
cd macos && swift build 2>&1 | tail -20
```

期望：`Build complete!`。若出现 `cannot find type X in scope`，说明依赖图算漏了一条边——**停下来报告 X 和它的定义位置**，不要自行把别的文件也搬过来。

- [ ] **Step 3: 补可见性**

编译若报某符号不可见，为其加 `public`。**先主动查扩展，并逐个确认成员可见性**（Task 3 与 Task 5 各栽了一次）。仅仅把扩展列出来是不够的——Task 5 的实现者跑了这条 grep，输出里**确实有** `extension CodingUserInfoKey`，但没有逐个检查其成员，结果 `skipLargeData` 仍是靠编译器报错才发现。命令只负责找出扩展，**判断成员是否需要 `public` 是人的工作**：

```bash
cd shared/HypoCore && grep -n "^extension \|^public extension " Sources/HypoCore/**/*.swift
```

逐一确认这些扩展的成员可见性。记录所有改成 `public` 的符号。

- [ ] **Step 4: 运行测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：193 通过，一个不少。

- [ ] **Step 5: 可移植性闸门**

```bash
cd shared/HypoCore && find Sources -name '*.swift' | while read f; do awk -v F="$f" '
  /^[[:space:]]*#if canImport\(AppKit\)/ { d++; next }
  d>0 && /^[[:space:]]*#endif/ { d--; next }
  d==0 { print F":"FNR": "$0 }
' "$f"; done | grep -E "import AppKit|NSPasteboard|NSImage|NSApplication|NSWorkspace|NSStatusItem|NSColor|NSEvent|NSWindow|NSMenu|NSAlert|NSViewController|NSCursor" | grep -vE ': *(///|//|\*)' ; echo "exit=$?"
```

期望：无输出，`exit=1`。

`StorageManager.swift` 另跑一次人工复核 grep（见「闸门与 CI 覆盖不到什么」）：

```bash
cd shared/HypoCore && grep -rn "NSHomeDirectory\|homeDirectoryForCurrentUser\|/Users/\|~/Library\|cachesDirectory" Sources/HypoCore/History/StorageManager.swift
```

不作为通过判据，把结果写进报告——`cachesDirectory` 在 iOS 上会被系统清理，这是第 2 期要处理的已知问题。

- [ ] **Step 6: 提交并推送**

```bash
git add -A
git commit -m "refactor(core): migrate batch 1 into HypoCore"
PRE_PUSH_ANDROID=0 PRE_PUSH_BACKEND=0 git push
```

- [ ] **Step 7: 确认 CI**

```bash
gh run list --branch feat/ios-hypocore --limit 3
```

确认 `HypoCore iOS Build` 与 `macOS Tests` 均为 `success`。

---

## Task 5B: DeviceIdentity 默认主机名的收尾（批次 2 落地后执行）

Task 4 的质量审查发现 `6d2ddaa` 那个 iOS 兼容修复虽然让构建通过了，但 iOS 分支的取值是坏的。三件事一起改：

**1. `ProcessInfo.processInfo.hostName` 在 iOS 真机上返回 `"localhost"`。** 模拟器是 macOS 进程所以看着正常，真机上 Apple 已锁死 `gethostname()` 一系。而 `"localhost"` 不含 `.local` 子串，初始化器里的清洗逻辑原样放行，它会直接成为用户可见的设备名。

**不要改用 `UIDevice.current.name` 来解决。** iOS 16+ 起它返回的是设备型号名（`"iPhone"`）而非用户起的名字，除非申请 `com.apple.developer.device-information.user-assigned-device-name` entitlement；本项目最低 iOS 17，拿到的就是型号名。更重要的是，**UIKit 不该进 core 模块**——这与剪贴板、生命周期、存储一律走协议注入的整体策略相悖。

**正确做法是让平台层供值**：`DeviceIdentity` 的初始化器本来就接受 `hostname:`，第 2 期的 iOS App 外壳自己持有 UIKit，构造时显式传入即可。core 里的默认值只是最后兜底，不必也不该做到完美。

**2. 改成 `String? = nil`，让 `defaultHostname` 回到 `private`。** 现在为了让 `public init` 的默认参数表达式能引用它，被迫标成了 `public`，白白扩大 API 面：

```swift
public init(userDefaults: UserDefaults = .standard, hostname: String? = nil) {
    let hostname = hostname ?? Self.defaultHostname
    ...
}

private static var defaultHostname: String { ... }
```

参数遮蔽后初始化器主体一行都不用改。对调用方源兼容：`DeviceIdentity()` 与 `DeviceIdentity(hostname: "x")` 都照常编译。

**3. 修正误导性的文档注释。** 现在写着「两条路径都可能返回带 `.local` 后缀的名字，下面的初始化器已经处理」——这暗示 iOS 路径没问题，而真正的失效模式（裸 `"localhost"`，根本没有 `.local` 后缀）恰恰是清洗逻辑抓不到的那种。

---

## Task 5C: 目录归属订正与 HypoCoreTests 骨架（批次 2 落地后执行）

同一轮审查提出的两条结构性意见，趁文件还少先做：

**1. `StorageManager.swift` 从 `History/` 移到 `Storage/`。** 它是一个以 UUID 为键的通用文件/blob 缓存，代码里不引用任何 history 相关类型。按当前唯一消费方命名它的归属，夸大了耦合；将来别的功能要用文件缓存时，得伸手进 `History/` 去拿。

**2. 现在就在 `shared/HypoCore/Package.swift` 里立起 `HypoCoreTests` 目标（可以是空的）。** 理由是审查者指出的一个真实机制：`@testable import HypoApp` **无法**触及被再导出的 `HypoCore` 的 internal 符号，所以每当一个类型搬进 core 而它的测试还留在 `HypoAppTests`，就会被迫把构造器之类改成 `public`。批次 1 的 `TokenBucket.init` 就是这么来的。目标先立起来，后续批次的测试可以直接用 `@testable import HypoCore`，不再累积这类"为测试而公开"的扩面。

`DeviceIdentity` 归入 `Models/` 是否合适（它有状态、读写 UserDefaults、做旧格式迁移，更像 service 而非值类型）——**暂不处理**。批次 2 正在把 `ClipboardEntry`、`PairedDevice` 这两个真正的模型搬进 `Models/`，等落地后再一起看更清楚。

---

## Task 5: 搬迁批次 2（9 个文件）

批次 1 落地后这些文件的前置依赖才齐备。

**Files（全部 `git mv`）:**

| 源 | 目标 |
|---|---|
| `Crypto/CryptoService.swift` | `Crypto/CryptoService.swift` |
| `Crypto/FileBasedKeyStore.swift` | `Crypto/FileBasedKeyStore.swift` |
| `Crypto/FileBasedPairingSigningKeyStore.swift` | `Crypto/FileBasedPairingSigningKeyStore.swift` |
| `Crypto/KeychainKeyStore.swift` | `Crypto/KeychainKeyStore.swift` |
| `Crypto/PairingSigningKeyStore.swift` | `Crypto/PairingSigningKeyStore.swift` |
| `Models/ClipboardEntry.swift` | `Models/ClipboardEntry.swift` |
| `Models/PairedDevice.swift` | `Models/PairedDevice.swift` |
| `Services/TempFileManager.swift` | `Files/TempFileManager.swift` |
| `Utilities/BonjourPublisher.swift` | `Discovery/BonjourPublisher.swift` |

（源路径前缀 `macos/Sources/HypoApp/`，目标前缀 `shared/HypoCore/Sources/HypoCore/`）

- [ ] **Step 1: 移动**

```bash
mkdir -p shared/HypoCore/Sources/HypoCore/{Crypto,Files}
git mv macos/Sources/HypoApp/Crypto/CryptoService.swift shared/HypoCore/Sources/HypoCore/Crypto/CryptoService.swift
git mv macos/Sources/HypoApp/Crypto/FileBasedKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/FileBasedKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/FileBasedPairingSigningKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/FileBasedPairingSigningKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/KeychainKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/KeychainKeyStore.swift
git mv macos/Sources/HypoApp/Crypto/PairingSigningKeyStore.swift shared/HypoCore/Sources/HypoCore/Crypto/PairingSigningKeyStore.swift
git mv macos/Sources/HypoApp/Models/ClipboardEntry.swift shared/HypoCore/Sources/HypoCore/Models/ClipboardEntry.swift
git mv macos/Sources/HypoApp/Models/PairedDevice.swift shared/HypoCore/Sources/HypoCore/Models/PairedDevice.swift
git mv macos/Sources/HypoApp/Services/TempFileManager.swift shared/HypoCore/Sources/HypoCore/Files/TempFileManager.swift
git mv macos/Sources/HypoApp/Utilities/BonjourPublisher.swift shared/HypoCore/Sources/HypoCore/Discovery/BonjourPublisher.swift
```

- [ ] **Step 2: 构建、补可见性、测试、闸门、提交、推送、确认 CI**

与 Task 4 的 Step 2~7 完全相同，提交信息用 `refactor(core): migrate batch 2 into HypoCore`。

**本批的特殊注意事项：**

- **`ClipboardEntry.swift` 是与 Android 互通的协议类型**。必须是纯 rename——不得改动任何 `Codable` conformance、CodingKeys 或序列化行为。改了就是协议破坏，两端会不兼容。
- **`KeychainKeyStore.swift` 有 iOS 运行时语义差异**（见「闸门与 CI 覆盖不到什么」）：macOS 默认走文件式 keychain，iOS 只有 data-protection keychain；`accessGroup` 在 iOS 需要 entitlement。**本任务不要改它**，只在提交信息里记一句待办，留给第 2 期。

---

## Task 6: 搬迁批次 3（3 个文件）

**Files:**

```bash
git mv macos/Sources/HypoApp/Crypto/DeviceKeyProvider.swift shared/HypoCore/Sources/HypoCore/Crypto/DeviceKeyProvider.swift
git mv macos/Sources/HypoApp/Pairing/PairingModels.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingModels.swift
git mv macos/Sources/HypoApp/Services/OptimizedHistoryStore.swift shared/HypoCore/Sources/HypoCore/History/OptimizedHistoryStore.swift
```

- [ ] **Step 1~7**：与 Task 4 相同的流程。提交信息 `refactor(core): migrate batch 3 into HypoCore`。

---

## Task 7: 搬迁 PairingSession

**Files:**

```bash
git mv macos/Sources/HypoApp/Pairing/PairingSession.swift shared/HypoCore/Sources/HypoCore/Pairing/PairingSession.swift
```

- [ ] **Step 1: 移动（同上）**

- [ ] **Step 2: 删除未使用的 AppKit import**

`PairingSession.swift` 顶部有一段：

```swift
#if canImport(AppKit)
import AppKit
#endif
```

整段删除——该文件没有任何 `NS*` 类型使用（已核实）。

- [ ] **Step 3~7**：构建、测试、闸门、提交（`refactor(core): move PairingSession into HypoCore`）、推送、确认 CI。

---

## Task 8: 原地拆分 HistoryStore.swift（不移动）

`macos/Sources/HypoApp/Services/HistoryStore.swift` 有 1187 行、两个职责。本任务只在 HypoApp 内部拆开，**不搬去 HypoCore**——拆分是内容改动，搬迁是位置改动，分开做才可审。

**Files:**
- Create: `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift`
- Modify: `macos/Sources/HypoApp/Services/HistoryStore.swift`（只留 actor）

- [ ] **Step 1: 拆出 ViewModel**

把 `HistoryStore.swift` 第 219 行（`@MainActor public final class ClipboardHistoryViewModel`）到文件末尾的全部内容，移入新文件 `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift`，顶部补上该段实际用到的 import：

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

- [ ] **Step 2: 精简原文件**

`HistoryStore.swift` 只保留第 1~218 行：顶部 import、第 22 行的 `extension UserDefaults: @retroactive @unchecked Sendable {}`、以及 `public actor HistoryStore`。删除其中的 `#if canImport(AppKit) import AppKit #endif`——actor 部分不使用任何 `NS*` 类型。

- [ ] **Step 3: 测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

期望：193 通过。这一步不动任何行为，测试数不应变化。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor(macos): split HistoryStore actor from its view model"
PRE_PUSH_ANDROID=0 PRE_PUSH_BACKEND=0 git push
```

---

## Task 9: 原地抽出三个平台协议（不移动）

让循环簇里的文件不再引用留在 HypoApp 的具体类型。协议放进 HypoCore，macOS 实现留在 HypoApp。

**Files:**
- Create: `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift`
- Create: `shared/HypoCore/Sources/HypoCore/Platform/AppLifecycleObserving.swift`
- Create: `shared/HypoCore/Sources/HypoCore/Platform/SystemClipboard.swift`
- Create: `macos/Sources/HypoApp/Platform/AppKitLifecycleObserver.swift`
- Create: `macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift`
- Modify: `macos/Sources/HypoApp/Services/ClipboardNotificationController.swift`、`TransportManager.swift`、`IncomingClipboardHandler.swift`、`App/AppContext.swift`

三个协议的完整定义、macOS 实现代码、以及 `TransportManager` / `IncomingClipboardHandler` 的改法，见本文档后面「协议定义与实现」一节（原 Task 14、15 的内容，未作改动，只是提前到此处执行且**不搬文件**）。

- [ ] **Step 1~5**：按该节逐条执行；每步之后 `cd macos && swift test` 必须 193 通过。

- [ ] **Step 6: 提交**

```bash
git commit -m "refactor(macos): put platform couplings behind protocols"
```

---

## Task 10: 搬迁循环依赖簇（16 个文件，纯 rename）

Task 8、9 完成后，这 16 个文件不再引用留在 HypoApp 的类型，可以一次性搬走。**这个提交必须是纯 rename**——`git show -M --summary` 应当只显示 renames，没有内容 diff。若某个文件仍需改动才能编译，说明 Task 8/9 有遗漏，回去补，不要在本任务里改内容。

**Files（16 个，源前缀 `macos/Sources/HypoApp/Services/`，目标前缀 `shared/HypoCore/Sources/HypoCore/`）:**

`CloudRelayConfiguration+Defaults.swift`、`CloudRelayTransport.swift`、`ConnectionStatusProber.swift`、`DualSyncTransport.swift`、`LanSyncTransport.swift`、`LanWebSocketServer.swift`、`LanWebSocketTransport.swift`、`TransportAnalytics.swift`、`TransportFrameCodec.swift`、`TransportManager.swift`、`TransportMetricsRecorder.swift`、`TransportProvider+Default.swift`、`WebSocketTransport.swift` → `Transport/`

`SyncEngine.swift`、`IncomingClipboardHandler.swift` → `Sync/`

`HistoryStore.swift` → `History/`

- [ ] **Step 1: 移动全部 16 个文件**

- [ ] **Step 2: 构建**

```bash
cd macos && swift build 2>&1 | tail -30
```

期望：`Build complete!`。任何 `cannot find` 错误都意味着 Task 8/9 有遗漏——报告缺的是哪个类型，不要就地修补。

- [ ] **Step 3: 确认是纯 rename**

```bash
git add -A && git diff --cached -M --summary | grep -c "^ rename"
```

期望：16。若有任何非 rename 的内容改动，说明混入了不该有的东西。

- [ ] **Step 4~7**：测试 193、闸门、提交（`refactor(core): migrate the transport/sync/history cluster`）、推送、确认 CI。

---

## 协议定义与实现（Task 9 执行内容）

### 9.1 `ClipboardNotificationScheduling`

把 `macos/Sources/HypoApp/Services/ClipboardNotificationController.swift:19` 处的 `public protocol ClipboardNotificationScheduling: AnyObject, Sendable { ... }` **整段声明**原样移入新文件 `shared/HypoCore/Sources/HypoCore/Notifications/ClipboardNotificationScheduling.swift`，方法签名一字不改。从原文件删除该声明，保留 `ClipboardNotificationHandling` 协议与 `ClipboardNotificationController` 类不动。

随后解绑两处把协议默认值绑到具体类型的参数：

- `TransportManager.swift:116` 的 `notificationController: ClipboardNotificationScheduling = ClipboardNotificationController.shared` → 去掉默认值，改为 `notificationController: ClipboardNotificationScheduling,`
- 在 `macos/Sources/HypoApp/App/AppContext.swift` 构造 `TransportManager` 处显式传入 `ClipboardNotificationController.shared`

`ClipboardHistoryViewModel`（Task 8 拆出，留在 HypoApp）里的同类默认值**保持原样**，因为它与控制器同在 HypoApp。

### 9.2 `AppLifecycleObserving`

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

macOS 实现，`macos/Sources/HypoApp/Platform/AppKitLifecycleObserver.swift`：

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

在 `TransportManager.swift` 中：删除文件末尾 `#if canImport(AppKit) private final class ApplicationLifecycleObserver { ... } #endif` 整段；把持有它的属性改为 `private let lifecycleObserver: AppLifecycleObserving?`；构造处改为调用注入实例的 `start(onActivate:onDeactivate:onTerminate:)`，三个闭包体保持原样。初始化器增加 `lifecycleObserver: AppLifecycleObserving? = nil,`，并在 `AppContext.swift` 构造点传入 `AppKitLifecycleObserver()`。

### 9.3 `SystemClipboard`（原计划称 `ClipboardWriting`，已改名）

**改名理由**：协议同时包含读操作（`currentText()`、`containsImage()`、`changeCount`），叫 `Writing` 会误导后来的读者。它尚无任何实现，改名零成本。

**实测补充的两个成员**（计划初稿遗漏，照初稿实现会编译不过）：

- **`changeCount`** —— `IncomingClipboardHandler.swift:90,92` 在写入剪贴板前后各取一次，把新值交给 `dispatcher.notifyClipboardApplied(changeCount:)`，好让 `ClipboardMonitor` 不把我们自己的写入误判成用户的新复制。**这是去重逻辑的一环，漏掉会导致同步回环。**
- **`imagePixelSize(from:)`** —— `IncomingClipboardHandler.swift:270` 用 `NSImage(data:)` 取图片尺寸存进历史元数据。这是图像解码而非剪贴板操作，但同样是平台能力，放进同一个协议以免再开第四个。


创建 `shared/HypoCore/Sources/HypoCore/Platform/SystemClipboard.swift`：

```swift
import Foundation

/// System clipboard access needed by the core.
///
/// Covers exactly what IncomingClipboardHandler used to do directly against
/// NSPasteboard: compare against current contents, then apply the payload.
@MainActor
public protocol SystemClipboard: AnyObject {
    /// Monotonic counter the platform bumps on every clipboard change.
    /// Used to tell our own writes apart from the user's copies.
    var changeCount: Int { get }
    func clear()
    func writeText(_ text: String)
    /// Returns false when the data cannot be decoded as an image on this platform.
    func writeImageData(_ data: Data) -> Bool
    func writeFileURL(_ url: URL)
    func currentText() -> String?
    func containsImage() -> Bool
    /// Pixel dimensions of encoded image data, for history metadata.
    /// Returns nil when the data is not a decodable image on this platform.
    func imagePixelSize(from data: Data) -> (width: Int, height: Int)?
}

/// Test double recording every write.
@MainActor
public final class RecordingClipboardWriter: SystemClipboard {
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

macOS 实现，`macos/Sources/HypoApp/Platform/AppKitClipboardWriter.swift`：

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// macOS implementation of ClipboardWriting, backed by NSPasteboard.
@MainActor
public final class AppKitClipboardWriter: SystemClipboard {
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

在 `IncomingClipboardHandler.swift` 中：删除第 2 行的裸 `import AppKit`；把 `private let pasteboard: NSPasteboard` 改为 `private let clipboard: SystemClipboard`；初始化器参数 `pasteboard: NSPasteboard = .general` 改为 `clipboard: SystemClipboard`（无默认值）。

`matchesCurrentClipboard` 中：`.text` 与 `.link` 分支改用 `clipboard.currentText()`；`.image` 分支改用 `clipboard.containsImage()`（原逻辑在有图时仍返回 `false`，保持不变）。

`applyToClipboard` 中：`pasteboard.clearContents()` → `clipboard.clear()`；`setString(_:forType: .string)` → `clipboard.writeText(_:)`；`.image` 分支改为：

```swift
        case .image:
            guard clipboard.writeImageData(payload.data) else {
                throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from data"])
            }
```

`.file` 分支写临时文件的逻辑不变，最后把文件 URL 交给 `clipboard.writeFileURL(tempURL)`。在 `AppContext.swift` 构造 `IncomingClipboardHandler` 处传入 `clipboard: AppKitClipboardWriter()`。

若 `IncomingClipboardHandlerTests` 构造 handler 时传了 `pasteboard:`，改为传 `RecordingClipboardWriter()`，断言从检查 `NSPasteboard.general` 改为检查 `writer.writtenTexts` 等记录属性。

---

## Task 11: 存储与历史持久化协议

Task 4 把 `StorageManager.swift` 原样搬进了 HypoCore，Task 10 搬进了 `HistoryStore` actor。本任务给两者加上 iOS 需要的注入点（spec §7.1、§7.2）。

`StorageManager.swift:23` 硬编码 `FileManager.default.urls(for: .cachesDirectory, ...)`，iOS 上 Caches 会被系统清理；`HistoryStore` actor 直接持有 `UserDefaults`，而 iOS 三个进程并发写历史时 App Group suite 跨进程不可靠。

- [ ] **Step 1~7**：见下方「存储协议定义」一节，逐条执行；每步之后 `cd macos && swift test` 必须 193 通过（新增测试后应为 195+）。

- [ ] **Step 8: 提交**

```bash
git commit -m "refactor(core): put storage and history behind protocols"
```

---

## 存储协议定义（Task 11 执行内容）

### 11.1 `StorageLocations`

先写失败测试 `macos/Tests/HypoAppTests/StorageLocationsTests.swift`：

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

运行 `cd macos && swift test --filter StorageLocationsTests`，期望编译失败 `cannot find 'FixedStorageLocations' in scope`。

再创建 `shared/HypoCore/Sources/HypoCore/Platform/StorageLocations.swift`：

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

在 `shared/HypoCore/Sources/HypoCore/History/StorageManager.swift` 中，把第 23 行附近计算 `caches` 与 `imagesDirectory` 的代码替换为注入：

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

文件内其余引用 `imagesDirectory` 处改为 `locations.imagesDirectory`。默认参数保证 macOS 行为不变。

### 11.2 `HistoryPersistence`

先写失败测试 `macos/Tests/HypoAppTests/HistoryPersistenceTests.swift`：

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

运行确认失败（`cannot find 'InMemoryHistoryPersistence' in scope`），再创建 `shared/HypoCore/Sources/HypoCore/Platform/HistoryPersistence.swift`：

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

在 `HistoryStore` actor 中把 `private let defaults: UserDefaults` 换成 `private let persistence: HistoryPersistence`，初始化器改为：

```swift
    public init(maxEntries: Int = 200, persistence: HistoryPersistence = UserDefaultsHistoryPersistence()) {
        self.maxEntries = max(1, maxEntries)
        self.persistence = persistence
    }
```

保留一个兼容初始化器，使现有调用点与测试不必改动：

```swift
    public init(maxEntries: Int = 200, defaults: UserDefaults) {
        self.init(maxEntries: maxEntries, persistence: UserDefaultsHistoryPersistence(defaults: defaults))
    }
```

五处调用点逐一替换（**键名不动**，仍为 `com.hypo.clipboard.history_entries` 与 `com.hypo.clipboard.file_storage_migration_v2`，否则升级后用户历史会丢失）：

| 原调用 | 替换为 |
|---|---|
| `defaults.data(forKey: Self.entriesKey)` | `try persistence.data(forKey: Self.entriesKey)` |
| `defaults.set(data, forKey: Self.entriesKey)` | `try persistence.setData(data, forKey: Self.entriesKey)` |
| `defaults.removeObject(forKey: Self.entriesKey)` | `try persistence.removeValue(forKey: Self.entriesKey)` |
| `defaults.bool(forKey: Self.fileStorageMigrationKey)` | `persistence.bool(forKey: Self.fileStorageMigrationKey)` |
| `defaults.set(true, forKey: Self.fileStorageMigrationKey)` | `persistence.setBool(true, forKey: Self.fileStorageMigrationKey)` |

若某调用点所在方法原先不是 `throws`，用 `try?` 保持原有的静默失败语义，不要改变方法签名。

---

## Task 12: 测试重定位与双平台运行

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

## Task 13: 验证既有构建与 CI 未受影响

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
