# iOS 前台版客户端实现计划（第 2 期）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出可在 iOS 模拟器运行、与 macOS 客户端真实双向同步剪贴板的 iOS App：配对、LAN + 云双通道、历史列表、`UIPasteControl` 发送。

**Architecture:** 第 1 期已把 45 个文件抽进 `shared/HypoCore`（macOS 与 iOS 共用），并留下六个平台协议接缝。本期不改 HypoCore 的任何逻辑，只做三件事——为六个接缝写 iOS 实现、建 `ios/Hypo.xcodeproj` 应用外壳、写 SwiftUI 界面。macOS 端全程不受影响。

**Tech Stack:** Swift 6 / SwiftUI / UIKit（仅 `UIPasteboard`、`UIPasteControl`、`UIApplication`）/ SwiftPM 本地依赖 / Xcode 26.6，iOS 部署目标 17.0

**参考:** `docs/superpowers/specs/2026-08-28-ios-app-design.md`（§4.4 工程构成、§5 前台传输、§7 数据、§8 错误处理、§9 第 2 期）

---

## 环境前提（开工前逐条确认）

本机 `xcode-select` 仍指向 Command Line Tools，**所有 iOS 命令必须前置环境变量**——但**只能内联，绝不能 `export`**：

```bash
# 正确：只影响这一条命令
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...

# 错误：会污染整个 shell
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

**为什么这条很重要**（Task 1 实测踩过）：`DEVELOPER_DIR` 不只影响 `xcodebuild`，它同时把 `swift test` 使用的工具链从 Command Line Tools 换成 Xcode 26.6。两者的测试运行器不同——Xcode 走 `swiftpm-testing-helper --testing-library swift-testing`。同一条 `cd macos && swift test`，不设该变量时 56 个测试通过，设了之后整个套件在跑第一个测试前就崩溃。

（该崩溃的根因是 `ClipboardNotificationController` 的测试守卫只识别 XCTest，已在 `8cf0ada` 修复，现在两种工具链都正常。但**内联而非 export** 仍是应当遵守的习惯——工具链切换会带来其它难以预料的差异。）

确认工具链：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices available | grep iPhone
```

期望：Xcode 26.6；有 iPhone 17 系列机型。**本机没有 iPhone 16**——CI 里写的是 `name=iPhone 16`，本地必须用 `name=iPhone 17`，照抄 CI 命令会报找不到设备。

**跑 Swift 测试前先确认没有 Hypo.app 在运行**：

```bash
pgrep -f HypoMenuBar && osascript -e 'quit app "Hypo"' || echo "未运行"
```

运行中的实例持有 LAN WebSocket 端口，会让 socket 测试无限挂起。`./scripts/build-macos.sh --no-launch` 可只构建不启动。

**基线**（每个任务后都不应下降）：

```bash
cd macos && swift test              # 56
cd shared/HypoCore && swift test    # 143
```

---

## 已知的坑（每一条都会真实咬人）

| 坑 | 后果 | 本计划在哪处理 |
|---|---|---|
| `ProcessInfo.processInfo.hostName` 在 iOS 真机返回 `"localhost"` | 设备名显示为 localhost | Task 4：App 显式传 `hostname:` |
| `StorageLocations` 默认写 Caches | iOS 存储紧张时图片被系统清除 | Task 3：注入 App 容器目录 |
| Bonjour 缺 Info.plist 键 | 发现静默失效，无任何报错 | Task 2：写入两个键；Task 9：UI 显式呈现权限状态 |
| iOS 16+ 读剪贴板弹授权窗 | 每次发送都打断用户 | Task 8：只用 `UIPasteControl` |
| `TransportManager` 要求非可选 `webSocketServer` | iOS 不跑服务端却必须传 | Task 6：构造但**永不** `start(port:)` |
| `LanWebSocketServer.start(port:)` 在 iOS 测试环境无法绑定 | `NWListener` 创建失败 | 全期不调用 |
| CI 模拟器执行器饥饿 | 定时器测试偶发失败 | CI 已加 `-parallel-testing-enabled NO` |

---

## 文件结构

### 新建：iOS 平台实现（SwiftPM target，CI 可编译验证）

放在 `shared/HypoiOS/`，独立 SwiftPM package，`platforms: [.iOS(.v17)]`，依赖 `HypoCore`。**这样绝大部分 iOS 代码不依赖 xcodeproj 即可被 CI 构建**，与第 1 期同样的策略。

| 文件 | 职责 |
|---|---|
| `Sources/HypoiOS/Platform/UIKitClipboard.swift` | `SystemClipboard` 的 `UIPasteboard` 实现 |
| `Sources/HypoiOS/Platform/UIKitLifecycleObserver.swift` | `AppLifecycleObserving` 的 `UIApplication` 实现 |
| `Sources/HypoiOS/Platform/AppContainerStorageLocations.swift` | `StorageLocations` 指向 App 容器的 Application Support |
| `Sources/HypoiOS/Notifications/UserNotificationScheduler.swift` | `ClipboardNotificationScheduling` 的 `UNUserNotificationCenter` 实现 |
| `Sources/HypoiOS/App/HypoiOSContext.swift` | 组装 `TransportManager` 及全部依赖的唯一入口 |
| `Sources/HypoiOS/ViewModels/HistoryListViewModel.swift` | 历史列表状态 + `RemoteEntryReceiving` 实现 |
| `Sources/HypoiOS/Views/HistoryListView.swift` | 历史列表界面 |
| `Sources/HypoiOS/Views/PairingView.swift` | 配对界面 |
| `Sources/HypoiOS/Views/SettingsView.swift` | 设置与权限状态 |
| `Sources/HypoiOS/Views/RootView.swift` | TabView 外壳 |
| `Tests/HypoiOSTests/` | 上述实现的测试 |

### 新建：应用外壳（必须有 Xcode）

| 文件 | 职责 |
|---|---|
| `ios/Hypo.xcodeproj` | iOS app target，依赖本地 package |
| `ios/Hypo/HypoApp.swift` | `@main`，创建 `HypoiOSContext` |
| `ios/Hypo/Info.plist` | 本地网络与 Bonjour 声明 |

### 修改

| 文件 | 改动 |
|---|---|
| `.github/workflows/ci.yml` | 新增 `ios-app-build` job |

---

## Task 1: 建立 HypoiOS package 骨架

**Files:**
- Create: `shared/HypoiOS/Package.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/HypoiOS.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/PackageSmokeTests.swift`

- [ ] **Step 1: 建目录与 package 定义**

```bash
cd /Users/derek/Documents/Projects/hypo/.worktrees/ios-hypocore
mkdir -p shared/HypoiOS/Sources/HypoiOS shared/HypoiOS/Tests/HypoiOSTests
```

写入 `shared/HypoiOS/Package.swift`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HypoiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HypoiOS",
            targets: ["HypoiOS"]
        )
    ],
    dependencies: [
        .package(path: "../HypoCore"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "HypoiOS",
            dependencies: [
                .product(name: "HypoCore", package: "HypoCore")
            ],
            path: "Sources/HypoiOS"
        ),
        .testTarget(
            name: "HypoiOSTests",
            dependencies: [
                "HypoiOS",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoiOSTests"
        )
    ]
)
```

**注意 `platforms` 只写 iOS。** 这个 package 不为 macOS 构建——它引用 `UIKit`，macOS 上不存在。因此本地 `swift build` 会失败，验证只能通过 `xcodebuild -destination 'generic/platform=iOS Simulator'`。

- [ ] **Step 2: 写占位类型与一个真实测试**

`shared/HypoiOS/Sources/HypoiOS/HypoiOS.swift`：

```swift
import Foundation
import HypoCore

/// Marker confirming HypoiOS can see HypoCore's public API.
/// Deleted once the real platform implementations land.
public enum HypoiOS {
    public static let maxAttachmentBytes = SizeConstants.maxAttachmentBytes
}
```

（第 1 期的 `HypoCore` 占位 enum 已被删除，所以这里用 `SizeConstants` —— 已实测确认它是 public 且值为 `10 * 1024 * 1024`。）

`shared/HypoiOS/Tests/HypoiOSTests/PackageSmokeTests.swift`：

```swift
import Foundation
import Testing
@testable import HypoiOS

@Suite("HypoiOS package wiring")
struct PackageSmokeTests {
    @Test("HypoiOS can read a HypoCore constant")
    func readsCoreConstant() {
        #expect(HypoiOS.maxAttachmentBytes == 10 * 1024 * 1024)
    }
}
```

- [ ] **Step 3: 为 iOS 构建**

```bash
cd shared/HypoiOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -scheme HypoiOS -destination 'generic/platform=iOS Simulator' -skipMacroValidation 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`。

- [ ] **Step 4: 在模拟器上跑测试**

```bash
cd shared/HypoiOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme HypoiOS -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation -enableCodeCoverage NO 2>&1 | grep -E "Test run with|TEST" | tail -3
```

期望：1 个测试通过，`TEST SUCCEEDED`。

- [ ] **Step 5: 确认 macOS 侧未受影响**

```bash
cd macos && swift test 2>&1 | grep "Test run with" | tail -1
cd shared/HypoCore && swift test 2>&1 | grep "Test run with" | tail -1
```

期望：56 与 143，一个不少。

- [ ] **Step 6: 提交**

```bash
git add shared/HypoiOS
git commit -m "build(ios): add the HypoiOS package skeleton"
```

---

## Task 2: CI 构建 HypoiOS

在写任何实现之前先建好验证通路——第 1 期的教训是本地检查不足以发现 iOS 问题。

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: 在 ios-core-build job 末尾追加两步**

```yaml
      - name: Build HypoiOS for iOS Simulator
        working-directory: shared/HypoiOS
        run: |
          xcodebuild build \
            -scheme HypoiOS \
            -destination 'generic/platform=iOS Simulator' \
            -skipMacroValidation
      - name: Run HypoiOS tests on iOS Simulator
        working-directory: shared/HypoiOS
        run: |
          xcodebuild test \
            -scheme HypoiOS \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            -skipMacroValidation \
            -enableCodeCoverage NO \
            -parallel-testing-enabled NO
```

**保留 `name=iPhone 16`**：CI runner 是 Xcode 16.4，有该机型；本地没有。**保留 `-parallel-testing-enabled NO`**：CI 模拟器上并行会导致定时器测试因执行器饥饿而假失败，第 1 期已实测确认。

不要改动其它四个 job。

- [ ] **Step 2: 校验 YAML**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(sorted(d['jobs'].keys()))"
```

期望：`['android-tests', 'backend-tests', 'ios-core-build', 'macos-tests', 'windows-tests']`

- [ ] **Step 3: 提交并推送，确认 CI 通过**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build and test HypoiOS on the iOS simulator"
PRE_PUSH_ANDROID=0 git push -u origin feat/ios-app
gh run list --branch feat/ios-app --limit 3
```

等 `HypoCore iOS Build` job 变绿再进入 Task 3。**这条通路不通，后面每个任务的 iOS 验证都是空的。**

---

## Task 3: StorageLocations 的 iOS 实现

**Files:**
- Modify: `shared/HypoiOS/Package.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/Platform/AppContainerStorageLocations.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/AppContainerStorageLocationsTests.swift`

- [ ] **Step 0: 给测试目标加上 HypoCore 依赖（先做，否则后面每个测试都会因错误原因失败）**

本任务起，每个测试文件都要 `import HypoCore`（不只是 `@testable import HypoiOS`）。SwiftPM 的 target 只能导入自己 `dependencies` 里声明的模块——`HypoiOSTests → HypoiOS → HypoCore` 这条传递链**不会**让 `HypoCore` 对测试目标可见。

不先补这一条的话，Step 2「确认测试失败」会报 `no such module 'HypoCore'` 而不是预期的 `cannot find 'AppContainerStorageLocations' in scope`——**失败原因不对，那一步就白做了**：TDD 先确认失败的意义在于验证测试确实在测你以为的东西。

把 `HypoiOSTests` 目标的 `dependencies` 改为：

```swift
        .testTarget(
            name: "HypoiOSTests",
            dependencies: [
                "HypoiOS",
                .product(name: "HypoCore", package: "HypoCore"),
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/HypoiOSTests"
        )
```

改完先跑一次现有的 smoke test 确认包仍然可解析：

```bash
cd /Users/derek/Documents/Projects/hypo/.worktrees/ios-hypocore/shared/HypoiOS && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -scheme HypoiOS -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation -enableCodeCoverage NO 2>&1 | grep -E "Test run with|error:" | tail -2
```

期望：1 个测试通过。

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("AppContainerStorageLocations")
struct AppContainerStorageLocationsTests {
    @Test("images directory sits under Application Support, not Caches")
    func usesApplicationSupport() {
        let locations = AppContainerStorageLocations()
        let path = locations.imagesDirectory.path

        #expect(path.contains("Application Support"))
        #expect(!path.contains("Caches"))
    }

    @Test("images directory is created on demand")
    func createsDirectory() throws {
        let locations = AppContainerStorageLocations()

        try FileManager.default.createDirectory(
            at: locations.imagesDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: locations.imagesDirectory.path,
            isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
```

- [ ] **Step 2: 确认失败**

```bash
cd shared/HypoiOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme HypoiOS -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation 2>&1 | grep -E "error:|cannot find" | head -3
```

期望：`cannot find 'AppContainerStorageLocations' in scope`。

- [ ] **Step 3: 实现**

```swift
import Foundation
import HypoCore

/// Where the iOS app stores clipboard images and received files.
///
/// macOS uses the user caches directory, but iOS evicts Caches under storage
/// pressure, which would silently drop images out of history. Application
/// Support inside the app container is not evicted.
///
/// Phase 3 adds a share extension and a notification service extension, at
/// which point this must point at the App Group container instead so all
/// three processes see the same files. That needs a paid developer account,
/// so it is deliberately out of scope here.
public struct AppContainerStorageLocations: StorageLocations {
    private let root: URL

    public init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.root = support.appendingPathComponent("com.hypo.clipboard")
    }

    public var imagesDirectory: URL {
        root.appendingPathComponent("images")
    }
}
```

- [ ] **Step 4: 确认通过**

同 Step 2 的命令，期望 3 个测试通过（含 Task 1 的 smoke test）。

- [ ] **Step 5: 提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): store blobs in Application Support, not Caches"
```

---

## Task 4: SystemClipboard 的 iOS 实现

这是第 2 期最容易出隐性错误的一处：协议有 9 个成员，其中 `changeCount` 关系到同步去重，漏掉不会编译报错但会造成复制一次同步两轮。

**Files:**
- Create: `shared/HypoiOS/Sources/HypoiOS/Platform/UIKitClipboard.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/UIKitClipboardTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import UIKit
import Testing
import HypoCore
@testable import HypoiOS

@Suite("UIKitClipboard", .serialized)
struct UIKitClipboardTests {
    @Test("writeText then currentText round-trips")
    @MainActor
    func textRoundTrips() {
        let clipboard = UIKitClipboard()

        clipboard.clear()
        clipboard.writeText("hello from test")

        #expect(clipboard.currentText() == "hello from test")
    }

    @Test("changeCount increases after a write")
    @MainActor
    func changeCountAdvances() {
        let clipboard = UIKitClipboard()
        let before = clipboard.changeCount

        clipboard.writeText("bump")

        #expect(clipboard.changeCount > before)
    }

    @Test("imagePixelSize returns nil for non-image data")
    @MainActor
    func pixelSizeNilForGarbage() {
        let clipboard = UIKitClipboard()

        #expect(clipboard.imagePixelSize(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("imagePixelSize reports the dimensions of a real image")
    @MainActor
    func pixelSizeForRealImage() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 7, height: 3))
        let png = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 7, height: 3))
        }
        let clipboard = UIKitClipboard()

        let size = clipboard.imagePixelSize(from: png)

        #expect(size?.width == 7)
        #expect(size?.height == 3)
    }

    @Test("containsImage is false after writing text")
    @MainActor
    func containsImageFalseForText() {
        let clipboard = UIKitClipboard()

        clipboard.clear()
        clipboard.writeText("not an image")

        #expect(clipboard.containsImage() == false)
    }
}
```

`.serialized` 是必要的：这些测试都操作同一个系统剪贴板，并行执行会互相覆盖。

- [ ] **Step 2: 确认失败**

```bash
cd shared/HypoiOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme HypoiOS -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation 2>&1 | grep -E "cannot find" | head -2
```

期望：`cannot find 'UIKitClipboard' in scope`。

- [ ] **Step 3: 实现**

```swift
import Foundation
import UIKit
import HypoCore

/// iOS implementation of SystemClipboard, backed by UIPasteboard.
///
/// Note on reading: `currentText()` and `containsImage()` touch the general
/// pasteboard, which on iOS 16+ shows the system paste prompt when the
/// content was not written by this app. The app therefore never calls them
/// speculatively — sending is driven by UIPasteControl, which grants access
/// without a prompt. They exist because IncomingClipboardHandler compares
/// against current contents before applying a payload, and at that point the
/// app has just written the content itself.
@MainActor
public final class UIKitClipboard: SystemClipboard {
    private let pasteboard: UIPasteboard

    public init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func clear() {
        pasteboard.items = []
    }

    public func writeText(_ text: String) {
        pasteboard.string = text
    }

    public func writeImageData(_ data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        pasteboard.image = image
        return true
    }

    public func writeFileURL(_ url: URL) {
        pasteboard.url = url
    }

    public func currentText() -> String? {
        pasteboard.string
    }

    public func containsImage() -> Bool {
        pasteboard.hasImages
    }

    public func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = image.scale
        return (width: Int(size.width * scale), height: Int(size.height * scale))
    }
}
```

**关于 `imagePixelSize` 的 scale**：`UIImage.size` 是点而非像素，PNG 解码出来的 `scale` 通常为 1，但不保证。乘以 `scale` 才是真实像素数，与 macOS 的 `NSImage.size`（已是像素）语义对齐。

- [ ] **Step 4: 确认通过**

期望 8 个测试通过。**若 `pixelSizeForRealImage` 失败**，先打印实际返回值再判断是 scale 处理错了还是渲染器产出的尺寸不同——不要直接改断言迁就实现。

- [ ] **Step 5: 提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): implement SystemClipboard over UIPasteboard"
```

---


### 执行记录：`UIPasteboard` 的读取会阻塞主线程

**按原计划实现会挂死，而且挂的是真实代码路径，不只是测试。** 记录在此，因为这一条会改变 `SystemClipboard` 在 iOS 上的语义。

第一次跑 `xcodebuild test` 时，`writeText then currentText round-trips` 永不返回。对挂住的进程 `sample` 之后拿到确切位置：

```
主线程 (com.apple.main-thread)
  UIKitClipboard.currentText()
    -[_UIConcretePasteboard string]
      _coerceItemToClass
        dispatch_semaphore_wait → semaphore_wait_trap

com.apple.Pasteboard.notification-queue
  +[PBServerConnection beginListeningToPasteboardChangeNotifications]
    -[NSNotificationCenter postNotificationName:]
      -[NSOperation waitUntilFinished] → __psynch_cvwait
```

看上去像两条线程互等：读取阻塞主线程，而变更通知的投递要等主线程。**但这个解释是不完整的。** 加了写穿缓存之后往返测试 0.039 秒通过，可专门测"读取外部写入内容"的用例照样挂死，`sample` 显示只有主线程卡在同一个信号量上，通知队列根本没参与。

真实结论更简单也更严重：**`-[UIPasteboard string]` 会阻塞调用线程等 pasteboard 服务返回，在没有宿主 app 的 xctest 包里这个等待永远不返回。** `SystemClipboard` 协议是 `@MainActor` 的，没有别的线程可以挪。

**因此 iOS 版的 `currentText()` / `containsImage()` 只回答自己写进去的内容，未命中返回 `nil` / `false`，绝不回落到读取 pasteboard。** 这不是为了绕开测试环境，而是本来就更对：

- 唯一的读取调用方是 `IncomingClipboardHandler.matchesCurrentClipboard`，用途是回声抑制——判断收到的内容是不是剪贴板上已有的，是则跳过。
- 回声抑制关心的永远是本 app 刚写进去的内容，缓存对这一档回答得精确。
- 缓存未命中意味着用户在别的 app 里复制过东西。为了一次后台去重判断去读它，代价是阻塞主线程 **加上给用户弹一个 iOS 16+ 的粘贴授权框**。
- 而 `nil` 落到去重逻辑上就是"不匹配 → 照常写入"，正是安全的一侧。

写穿缓存靠 `changeCount` 判活：写入后记下 `pasteboard.changeCount`，读取时比对，不等则说明别人写过。`changeCount` 本身不阻塞也不弹框（挂死发生在 `_coerceItemToClass`，即内容取值那一步）。

**留给 Task 10 的验证项**：真实 app 外壳里有前台窗口，读取外部内容会弹粘贴框而不是永久阻塞。届时要确认端到端流程里用户看不到任何非预期的粘贴授权框。


## Task 5: AppLifecycleObserving 与通知的 iOS 实现

**Files:**
- Create: `shared/HypoiOS/Sources/HypoiOS/Platform/UIKitLifecycleObserver.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/Notifications/UserNotificationScheduler.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/UIKitLifecycleObserverTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import UIKit
import Testing
import HypoCore
@testable import HypoiOS

@Suite("UIKitLifecycleObserver")
struct UIKitLifecycleObserverTests {
    @Test("posting the foreground notification fires onActivate")
    @MainActor
    func activateFires() async {
        let observer = UIKitLifecycleObserver()
        let activated = Locked(false)

        observer.start(
            onActivate: { activated.withLock { $0 = true } },
            onDeactivate: {},
            onTerminate: {}
        )
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        let fired = await waitUntil(timeout: .seconds(2)) { activated.withLock { $0 } }
        #expect(fired)
        observer.stop()
    }

    @Test("stop removes the observers")
    @MainActor
    func stopDetaches() async {
        let observer = UIKitLifecycleObserver()
        let count = Locked(0)

        observer.start(
            onActivate: { count.withLock { $0 += 1 } },
            onDeactivate: {},
            onTerminate: {}
        )
        observer.stop()
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(200))

        #expect(count.withLock { $0 } == 0)
    }
}
```

这两个测试需要 `Locked` 和 `waitUntil`，它们定义在 `HypoCore` 的测试目标里，**HypoiOSTests 看不到**。在 `shared/HypoiOS/Tests/HypoiOSTests/TestSupport.swift` 里各写一份：

```swift
import Foundation
import Testing

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@discardableResult
func waitUntil(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: pollInterval)
    }
    return await condition()
}
```

- [ ] **Step 2: 确认失败**，期望 `cannot find 'UIKitLifecycleObserver' in scope`。

- [ ] **Step 3: 实现生命周期观察者**

```swift
import Foundation
import UIKit
import HypoCore

/// iOS implementation of AppLifecycleObserving.
///
/// macOS listens to NSApplication notifications; the iOS equivalents are
/// didBecomeActive, willResignActive and willTerminate. Note that on iOS
/// willTerminate is not guaranteed — the system can kill a suspended app
/// without delivering it — so nothing that must happen should depend on it.
public final class UIKitLifecycleObserver: AppLifecycleObserving {
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in onActivate() })
        tokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in onDeactivate() })
        tokens.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in onTerminate() })
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

- [ ] **Step 4: 实现通知调度器**

`shared/HypoiOS/Sources/HypoiOS/Notifications/UserNotificationScheduler.swift`：

```swift
import Foundation
import UserNotifications
import HypoCore

/// iOS implementation of ClipboardNotificationScheduling.
///
/// Phase 2 only posts local notifications while the app is running. Phase 4
/// adds APNs-driven delivery through a notification service extension, which
/// needs a paid developer account.
public final class UserNotificationScheduler: ClipboardNotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private weak var handler: ClipboardNotificationHandling?

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func configure(handler: ClipboardNotificationHandling) {
        self.handler = handler
    }

    public func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func deliverNotification(for entry: ClipboardEntry) {
        let content = UNMutableNotificationContent()
        content.title = "Clipboard received"
        content.body = entry.content.previewDescription
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: entry.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    public func deliverStatusNotification(deviceId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: "status-\(deviceId)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
```

（**`previewDescription` 定义在 `ClipboardContent` 上，不在 `ClipboardEntry` 上**——所以要写 `entry.content.previewDescription`。`ClipboardEntry` 本身没有任何 public 摘要属性；文件里那个 `previewText` 属于 `CGSizeValue` 且是 internal。这处最初写错了，是因为按 grep 到的行号推断归属，而那个文件里定义了三个以上类型。）

- [ ] **Step 5: 确认全部通过并提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): implement lifecycle observation and local notifications"
```

---

## Task 6: 组装上下文

把六个接缝接到 `TransportManager` 上。这是第 2 期的接线中枢。

**Files:**
- Create: `shared/HypoiOS/Sources/HypoiOS/App/HypoiOSContext.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/HypoiOSContextTests.swift`

- [ ] **Step 1: 先读 TransportManager 的初始化器**

```bash
sed -n "$(grep -n 'public init(' ../HypoCore/Sources/HypoCore/Transport/TransportManager.swift | head -1 | cut -d: -f1),+20p" ../HypoCore/Sources/HypoCore/Transport/TransportManager.swift
```

**必填参数**（无默认值）：`provider`、`webSocketServer`、`notificationController`、`clipboard`。其余有默认值。

**`webSocketServer` 是非可选的，但 iOS 绝不能启动它。** 第 1 期定的设计是 iOS 只做 LAN 发起端：iOS 会挂起后台进程，监听端口会让对端看到设备频繁上下线。已实测确认 `LanWebSocketServer` 的构造不创建 `NWListener`——只有 `start(port:)` 会。

**但光"不主动调 `start(port:)`"是不够的。** 实测 `TransportManager.init` 的最后一个参数是 `autoStartLanServices: Bool = true`，默认为真；它在非 AppKit 平台上会立刻 `Task { await activateLanServices() }`，而 `activateLanServices()` 第一件事就是 `try webSocketServer.start(port: lanConfiguration.port)`，第二件事是 `publisher.start(with:)`。也就是说**按原计划写的 `HypoiOSContext` 一构造就会在 iOS 上开监听并广播 Bonjour**，正好是设计要禁止的行为，而且多半会在测试包里触发第 1 期见过的 `SO_NECP_LISTENUUID` 失败。

传 `autoStartLanServices: false` 也不对——`activateLanServices()` 一共做五件事：

| # | 动作 | iOS 是否需要 |
|---|---|---|
| 1 | `webSocketServer.start(port:)` | ✘ 禁止 |
| 2 | `publisher.start(with:)` 广播 Bonjour | ✘ 禁止 |
| 3 | `browser.start()` + 发现事件流 | ✔ 必需（要发现对端才能发起连接） |
| 4 | prune / health-check / network-monitor 任务 | ✔ 需要 |
| 5 | `startAutoConnect()` 云端中转 | ✔ 需要 |

关掉整个开关会连 3–5 一起丢掉，iOS 就发现不了任何对端。需要的是"只做客户端"这一档。

代码里恰好有个暗门：启动监听的守卫是 `port >= 0`，广播的守卫是 `port > 0`，所以传一个负数端口正好跳过 1 和 2 而保留 3–5。**不要用这个暗门**——它把一个载荷很重的设计决策藏在一个魔数里，哪天有人把 `>= 0` 顺手"修"成 `> 0`，iOS 就会静默开始监听，而且没有任何测试会红。这个决策要写在类型里。

- [ ] **Step 2: 给 HypoCore 加一个显式的 LAN 角色**

在 `TransportManager.swift` 里加：

```swift
/// Whether this device offers a LAN listener that peers can dial.
///
/// macOS and Windows do. iOS does not: the system suspends the app in the
/// background, so an advertised listener would make peers see the device
/// flapping online and offline. A client-only manager still browses for
/// peers, prunes them, health-checks them and connects to the cloud relay —
/// it just never binds a socket or advertises one.
public enum LanRole: Sendable {
    case peer
    case clientOnly
}
```

初始化器加 `lanRole: LanRole = .peer`（默认值让 macOS 与 Windows 的所有调用点原样通过），`activateLanServices()` 里给前两步加守卫：

```swift
if lanRole == .peer, !isServerRunning, lanConfiguration.port >= 0 {
```
```swift
if lanRole == .peer, !isAdvertising, lanConfiguration.port > 0 {
```

改完先跑 macOS 全量，确认 56 + 143 仍然全绿再往下走。

- [ ] **Step 3: 写失败测试**

```swift
import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("HypoiOSContext")
struct HypoiOSContextTests {
    @Test("context builds without starting a LAN listener")
    @MainActor
    func buildsWithoutListening() async {
        let context = HypoiOSContext()

        #expect(context.transportManager != nil)
        #expect(context.webSocketServer.listeningPort == nil)
    }

    @Test("storage is the app container, not caches")
    @MainActor
    func usesAppContainerStorage() {
        let context = HypoiOSContext()

        #expect(context.storageLocations.imagesDirectory.path.contains("Application Support"))
    }
}
```

（`listeningPort` 实测是 `public var listeningPort: NWEndpoint.Port? { listener?.port }` —— 未调用 `start(port:)` 时 `listener` 为 nil，所以返回 nil。这个断言直接证明"没有在监听"。）

- [ ] **Step 4: 确认失败**，期望 `cannot find 'HypoiOSContext' in scope`。

- [ ] **Step 5: 实现**

```swift
import Foundation
import UIKit
import HypoCore

/// Builds and owns the iOS app's object graph.
///
/// This is the one place that knows how HypoCore's platform seams are filled
/// on iOS. Everything else takes what it needs from here.
@MainActor
public final class HypoiOSContext {
    public let identity: DeviceIdentity
    public let storageLocations: StorageLocations
    public let clipboard: UIKitClipboard
    public let lifecycleObserver: UIKitLifecycleObserver
    public let notificationScheduler: UserNotificationScheduler
    public let webSocketServer: LanWebSocketServer
    public let transportManager: TransportManager

    public init() {
        // iOS returns "localhost" from ProcessInfo.processInfo.hostName on
        // device, so the core's fallback is useless here. Supply the device's
        // own name explicitly instead.
        self.identity = DeviceIdentity(hostname: UIDevice.current.name)

        self.storageLocations = AppContainerStorageLocations()
        self.clipboard = UIKitClipboard()
        self.lifecycleObserver = UIKitLifecycleObserver()
        self.notificationScheduler = UserNotificationScheduler()

        // Constructed because TransportManager requires it, never started:
        // iOS is a LAN client only. Constructing does not bind a listener.
        self.webSocketServer = LanWebSocketServer(localDeviceId: identity.deviceIdString)

        let provider = DefaultTransportProvider(server: webSocketServer)

        self.transportManager = TransportManager(
            provider: provider,
            webSocketServer: webSocketServer,
            notificationController: notificationScheduler,
            clipboard: clipboard,
            lifecycleObserver: lifecycleObserver,
            lanRole: .clientOnly
        )
    }
}
```

（实测签名是 `init(localDeviceId: String? = nil, heartbeatInterval: TimeInterval = 60, enableHeartbeat: Bool = true)` —— **没有 `port:` 参数**，端口是 `start(port:)` 时才指定的，这也正是构造不会绑定监听器的原因。）

- [ ] **Step 6: 确认通过并提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): assemble the iOS object graph"
```

---


### 执行记录：CI 的 iOS 任务此前一直看不见测试失败

**`xcodebuild` 在 Swift Testing 测试失败时仍然打印 `** TEST SUCCEEDED **` 并返回 0。** 它统计的是 XCTest 结果，而 HypoCore 和 HypoiOS 两个包里一个 XCTest 用例都没有，于是它看到"零失败"判绿。

用 workflow 里一模一样的调用形状复现（把 `HypoiOSContext` 的 `lanRole` 改成 `.peer`，让监听器断言失败）：

```
✘ Test run with 15 tests failed after 1.272 seconds with 1 issue.
** TEST SUCCEEDED **
EXIT=0
```

**后果**：`ios-core-build` 里的两个测试步骤从建立起就一直是绿的，但那个绿不代表任何事情。第 1 期"iOS 117 个测试在 CI 上全绿"这个结论是建立在一个瞎信号上的，需要重新核实。（第 1 期确实抓到过 18 个 iOS 失败，那是人工读日志发现的，不是 CI 判红。）

**修法**：`scripts/run-ios-tests.sh` 包一层，自己检查 Swift Testing 的汇总行。三种失败都要判红：

1. `xcodebuild` 自己返回非零——构建失败、模拟器不可用，这些仍然是真失败，照常传递。
2. 输出里出现 `✘ Test run with`——测试真的红了。
3. 输出里**没有任何** `✔ Test run with` 汇总——套件压根没跑起来，这种绿同样是假的。

第 3 条不是多余的：如果 scheme 名写错或测试 target 没被包含，前两条都不会触发。

已双向验证：`.peer` 构建下退出 1 并指名失败的测试，`.clientOnly` 下退出 0。

**教训**：这条和本期的另外两个坑（`Host.current()` 只有 iOS CI 抓得到、`previewDescription` 的归属靠推断）是同一类——**用来验证的工具本身没有被验证过**。任何新建的检查，都应该先构造一次确定的失败，确认它真的会红，再开始信任它的绿。


## Task 7: 历史列表 ViewModel

**Files:**
- Create: `shared/HypoiOS/Sources/HypoiOS/ViewModels/HistoryListViewModel.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/HistoryListViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("HistoryListViewModel")
struct HistoryListViewModelTests {
    private func makeEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            deviceId: "test-device",
            originDeviceName: "Test",
            content: .text(text),
            transportOrigin: .lan
        )
    }

    @Test("loading reflects what the store holds")
    @MainActor
    func loadsFromStore() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("first"))
        let viewModel = HistoryListViewModel(store: store)

        await viewModel.load()

        #expect(viewModel.entries.count == 1)
    }

    @Test("search filters by content")
    @MainActor
    func searchFilters() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("alpha"))
        _ = await store.insert(makeEntry("beta"))
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        viewModel.searchText = "alph"

        #expect(viewModel.visibleEntries.count == 1)
    }

    @Test("an incoming remote entry lands in the list")
    @MainActor
    func remoteEntryArrives() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let viewModel = HistoryListViewModel(store: store)
        let entry = makeEntry("from mac")
        _ = await store.insert(entry)

        await viewModel.handleIncomingRemoteEntry(entry, duplicate: nil)

        #expect(viewModel.entries.contains { $0.id == entry.id })
    }
}
```

**实测确认过的签名**（照抄即可，不要改）：

```swift
public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    deviceId: String,
    originPlatform: DevicePlatform? = nil,
    originDeviceName: String? = nil,
    content: ClipboardContent,
    isPinned: Bool = false,
    isEncrypted: Bool = false,
    transportOrigin: TransportOrigin? = nil
)
```

注意**没有 `deviceName:` 参数**，是 `originDeviceName:`；`content:` 排在 `deviceId:` 之后。`TransportOrigin` 只有 `.lan` 和 `.cloud` 两个成员。

- [ ] **Step 2: 确认失败**，期望 `cannot find 'HistoryListViewModel' in scope`。

- [ ] **Step 3: 实现**

```swift
import Foundation
import Combine
import HypoCore

/// Backs the history list and receives entries arriving from paired devices.
@MainActor
public final class HistoryListViewModel: ObservableObject, RemoteEntryReceiving {
    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public var searchText: String = ""

    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    public var visibleEntries: [ClipboardEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.matches(query: searchText) }
    }

    public func load() async {
        entries = await store.all()
    }

    public func handleIncomingRemoteEntry(_ entry: ClipboardEntry, duplicate: ClipboardEntry?) async {
        entries = await store.all()
    }

    public func remove(id: UUID) async {
        await store.remove(id: id)
        entries = await store.all()
    }

    public func togglePin(id: UUID) async {
        entries = await store.togglePin(id: id)
    }

    public func clearAll() async {
        await store.clear()
        entries = await store.all()
    }
}
```

**不要用 `content.previewDescription` 过滤。** `ClipboardEntry` 上有个公开的 `matches(query:)`，正是为搜索而写的，会检查设备 ID、完整正文、链接、图片 altText 和文件名；`macos/Sources/HypoApp/App/HypoMenuBarApp.swift:1494` 用的就是它。改用它有三个理由：

1. `previewDescription` 在 100 字符处截断，超出部分永远搜不到。
2. 对图片它匹配的是格式化后的 `"名字 · PNG · 1.2 MB"` 字符串，而不是 altText。
3. 它搜不到设备 ID。

两端用同一个谓词，搜索行为才一致。已用一个把关键词放在第 200 个字符处的用例把这个差别钉住。

（`previewDescription` 本身定义在 `ClipboardContent` 上而非 `ClipboardEntry` 上——取用要经 `.content`。这一点在别处仍然成立，比如通知正文。）

- [ ] **Step 4: 确认通过并提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): add the history list view model"
```

---

## Task 8: 界面

四个视图。**本任务不写测试**——SwiftUI 视图的单元测试价值低于成本，验证方式是 Task 10 在模拟器里实际运行并肉眼确认。

**Files:**
- Create: `shared/HypoiOS/Sources/HypoiOS/Views/HistoryListView.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/Views/PairingView.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/Views/SettingsView.swift`
- Create: `shared/HypoiOS/Sources/HypoiOS/Views/RootView.swift`

- [ ] **Step 1: 历史列表**

```swift
import SwiftUI
import HypoCore

public struct HistoryListView: View {
    @ObservedObject private var viewModel: HistoryListViewModel

    public init(viewModel: HistoryListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.visibleEntries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.content.previewDescription)
                            .lineLimit(2)
                        Text(entry.originDeviceName ?? entry.deviceId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await viewModel.remove(id: entry.id) }
                        }
                        Button("Pin") {
                            Task { await viewModel.togglePin(id: entry.id) }
                        }
                    }
                }
            }
            .searchable(text: $viewModel.searchText)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Task { await viewModel.clearAll() }
                    }
                }
            }
            .task { await viewModel.load() }
        }
    }
}
```

- [ ] **Step 2: 配对界面**

```swift
import SwiftUI
import HypoCore

public struct PairingView: View {
    @ObservedObject private var viewModel: RemotePairingViewModel
    private let relayHint: URL?

    public init(viewModel: RemotePairingViewModel, relayHint: URL?) {
        self.viewModel = viewModel
        self.relayHint = relayHint
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(viewModel.statusMessage)
                    .multilineTextAlignment(.center)

                if case let .displaying(code, _) = viewModel.state {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let countdown = viewModel.countdownText {
                    Text(countdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Request pairing code") {
                    viewModel.start(service: "_hypo._tcp.", port: 0, relayHint: relayHint)
                }
                .buttonStyle(.borderedProminent)

                Button("Reset") { viewModel.reset() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Pair a device")
        }
    }
}
```

**`start(service:port:relayHint:)` 的 `port` 传 0**：iOS 不监听，没有端口可宣告。实测确认 `PairingSession` 只把 port 原样存进配对载荷转发给对端，不做非零校验（`PairingSession.swift:40,55,125`），所以传 0 是安全的——对端拿到 0 就知道这台设备不接受入站连接。

- [ ] **Step 3: 设置界面**

必须显式呈现两个权限状态。**本地网络权限被拒后 Bonjour 会静默失效且无任何报错**，不显示的话用户只会觉得 LAN 莫名其妙不工作。

```swift
import SwiftUI
import UIKit
import UserNotifications
import HypoCore

public struct SettingsView: View {
    @State private var notificationStatus: String = "Checking…"

    private let deviceName: String
    private let deviceId: String

    public init(deviceName: String, deviceId: String) {
        self.deviceName = deviceName
        self.deviceId = deviceId
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("This device") {
                    LabeledContent("Name", value: deviceName)
                    LabeledContent("ID", value: String(deviceId.prefix(8)))
                }

                Section("Permissions") {
                    LabeledContent("Notifications", value: notificationStatus)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local network")
                        Text("If LAN sync never connects, iOS may have denied local network access. Grant it in Settings › Privacy & Security › Local Network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationStatus = switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: "Granted"
                case .denied: "Denied — background delivery will not work"
                case .notDetermined: "Not requested"
                @unknown default: "Unknown"
                }
            }
        }
    }
}
```

**iOS 无法查询本地网络权限状态**——系统没有提供 API。所以这里只能给出说明文字和跳转入口，不能显示实际状态。这是平台限制，不是偷懒。

- [ ] **Step 4: 根视图与发送按钮**

```swift
import SwiftUI
import UIKit
import HypoCore

public struct RootView: View {
    private let context: HypoiOSContext
    @StateObject private var historyViewModel: HistoryListViewModel
    @StateObject private var pairingViewModel: RemotePairingViewModel

    public init(context: HypoiOSContext, historyStore: HistoryStore) {
        self.context = context
        _historyViewModel = StateObject(wrappedValue: HistoryListViewModel(store: historyStore))
        _pairingViewModel = StateObject(wrappedValue: RemotePairingViewModel(
            identity: context.identity
        ))
    }

    public var body: some View {
        TabView {
            HistoryListView(viewModel: historyViewModel)
                .tabItem { Label("History", systemImage: "list.bullet") }

            PairingView(viewModel: pairingViewModel, relayHint: nil)
                .tabItem { Label("Pair", systemImage: "link") }

            SettingsView(
                deviceName: context.identity.deviceName,
                deviceId: context.identity.deviceIdString
            )
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
```

发送按钮用 `UIPasteControl`，它是 iOS 上**唯一不弹授权窗**的读剪贴板方式。SwiftUI 没有原生封装，需要 `UIViewRepresentable`：

```swift
import SwiftUI
import UIKit

/// The system paste button. Tapping it grants this app one-shot access to the
/// pasteboard without the "allow paste?" prompt that a programmatic read
/// triggers on iOS 16 and later.
public struct PasteButton: UIViewRepresentable {
    private let onPaste: (String) -> Void

    public init(onPaste: @escaping (String) -> Void) {
        self.onPaste = onPaste
    }

    public func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        return control
    }

    public func updateUIView(_ uiView: UIPasteControl, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    public final class Coordinator: NSObject, UIPasteConfigurationSupporting {
        private let onPaste: (String) -> Void

        init(onPaste: @escaping (String) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(
                forAccepting: NSString.self
            )
        }

        public override func paste(itemProviders: [NSItemProvider]) {
            for provider in itemProviders {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let string = object as? String else { return }
                    Task { @MainActor in self.onPaste(string) }
                }
            }
        }
    }
}
```

把它加进 `HistoryListView` 的工具栏：

```swift
                ToolbarItem(placement: .topBarLeading) {
                    PasteButton { text in
                        Task { await viewModel.sendText(text) }
                    }
                }
```

并在 `HistoryListViewModel` 上补一个发送方法——它需要 `SyncEngine`，所以 ViewModel 的初始化器要多接一个参数：

```swift
    public func sendText(_ text: String) async {
        // Deliberately inert until Task 9 wires the SyncEngine. Task 8 exists
        // to get the UI on screen and tappable; sending needs a paired peer,
        // which the UI cannot provide on its own.
    }
```

**这个空实现只允许存在到 Task 9。** 若 Task 9 结束后它还在，说明发送根本没接上——Task 10 Step 5 的第 7 条会当场发现。

- [ ] **Step 5: 构建确认并提交**

```bash
cd shared/HypoiOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -scheme HypoiOS -destination 'generic/platform=iOS Simulator' -skipMacroValidation 2>&1 | tail -3
git add shared/HypoiOS
git commit -m "feat(ios): add history, pairing and settings screens"
```

---

## Task 9: 接上真实发送与接收

**Files:**
- Modify: `shared/HypoiOS/Sources/HypoiOS/ViewModels/HistoryListViewModel.swift`
- Modify: `shared/HypoiOS/Sources/HypoiOS/App/HypoiOSContext.swift`
- Create: `shared/HypoiOS/Tests/HypoiOSTests/SendPathTests.swift`

- [ ] **Step 1: 把 ViewModel 接到发送路径**

**发送不经过 `TransportManager`。** 实测确认它没有 `send` 或 `broadcast` 方法——它只提供 `loadTransport()`。真实路径是构造 `SyncEngine` 再 `transmit`，macOS 侧在 `ClipboardHistoryViewModel.swift:625-660` 就是这么做的。

`HistoryListViewModel` 的初始化器改为：

```swift
    private let transportManager: TransportManager?
    private let identity: DeviceIdentityProviding?

    public init(
        store: HistoryStore,
        transportManager: TransportManager? = nil,
        identity: DeviceIdentityProviding? = nil
    ) {
        self.store = store
        self.transportManager = transportManager
        self.identity = identity
    }
```

`sendText` 按 macOS 的流程实现：

```swift
    public func sendText(_ text: String) async {
        guard let transportManager, let identity else { return }

        let entry = ClipboardEntry(
            deviceId: identity.deviceIdString,
            originPlatform: identity.platform,
            originDeviceName: identity.deviceName,
            content: .text(text),
            transportOrigin: .lan
        )

        let transport = transportManager.loadTransport()
        let keyProvider = KeychainDeviceKeyProvider()
        let cryptoService = CryptoService()

        // DualSyncTransport builds separate envelopes for LAN and cloud, each
        // with its own nonce, so it needs the crypto service and key provider.
        if let dualTransport = transport as? DualSyncTransport {
            dualTransport.configure(cryptoService: cryptoService, keyProvider: keyProvider)
        }

        let syncEngine = SyncEngine(
            transport: transport,
            cryptoService: cryptoService,
            keyProvider: keyProvider,
            localDeviceId: identity.deviceIdString,
            localPlatform: identity.platform
        )
        await syncEngine.establishConnection()

        let payload = ClipboardPayload(
            contentType: .text,
            data: Data(text.utf8),
            metadata: nil
        )

        // Sending is per-target: there is no broadcast. Try every paired
        // device, best effort — one failure must not stop the others.
        for device in transportManager.pairedDevices {
            do {
                try await syncEngine.transmit(
                    entry: entry,
                    payload: payload,
                    targetDeviceId: device.id
                )
                transportManager.updatePairedDeviceLastSeen(device.id, lastSeen: Date())
            } catch {
                continue
            }
        }

        _ = await store.insert(entry)
        entries = await store.all()
    }
```

**在写之前先核对两处签名**，因为它们决定这段代码能否编译：

```bash
grep -n "public init(" ../HypoCore/Sources/HypoCore/Sync/SyncEngine.swift | head -2
sed -n "$(grep -n 'public init(' ../HypoCore/Sources/HypoCore/Sync/SyncEngine.swift | head -1 | cut -d: -f1),+8p" ../HypoCore/Sources/HypoCore/Sync/SyncEngine.swift
grep -n "public init(" ../HypoCore/Sources/HypoCore/Models/ClipboardEntry.swift | sed -n '2p'
grep -rn "struct ClipboardPayload" -A 8 ../HypoCore/Sources/HypoCore/ | head -12
```

macOS 的调用点是 `macos/Sources/HypoApp/Services/ClipboardHistoryViewModel.swift:625-660`，可以直接对照。若 `ClipboardPayload` 的构造或 `contentType` 枚举名与上面不同，以真实代码为准并在报告里贴出差异。

- [ ] **Step 2: 在上下文里接线**

`HypoiOSContext` 增加 `historyStore` 与 `historyViewModel`，并把 ViewModel 注册为接收方：

```swift
    public let historyStore: HistoryStore
    public private(set) var historyViewModel: HistoryListViewModel!

    // 在 init 末尾：
    self.historyStore = HistoryStore()
    let viewModel = HistoryListViewModel(store: historyStore, transportManager: transportManager)
    self.historyViewModel = viewModel
    transportManager.setHistoryViewModel(viewModel)
    notificationScheduler.requestAuthorizationIfNeeded()
```

`setHistoryViewModel` 接受 `any RemoteEntryReceiving`，`HistoryListViewModel` 已实现该协议。

- [ ] **Step 3: 写测试证明发送路径被调用**

```swift
import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("Send path")
struct SendPathTests {
    @Test("sendText with no transport does not crash and leaves the list unchanged")
    @MainActor
    func sendWithoutTransportIsSafe() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let viewModel = HistoryListViewModel(store: store)

        await viewModel.sendText("no transport attached")

        #expect(viewModel.entries.isEmpty)
    }
}
```

这个测试覆盖的是"没有传输时不崩"，真实发送要到 Task 10 在模拟器里对着 Mac 验证——单元测试无法验证跨设备同步。

- [ ] **Step 4: 确认通过并提交**

```bash
git add shared/HypoiOS
git commit -m "feat(ios): wire sending and receiving through TransportManager"
```

---

## Task 10: 应用外壳与端到端验证

**这一步必须有 Xcode，且产出的是唯一能证明第 2 期真正可用的证据。**

**Files:**
- Create: `ios/Hypo.xcodeproj`
- Create: `ios/Hypo/HypoApp.swift`
- Create: `ios/Hypo/Info.plist`

- [ ] **Step 1: 用 Xcode 建 app target**

在 Xcode 中新建 iOS App 项目，保存到 `ios/`，产品名 `Hypo`，界面 SwiftUI，语言 Swift，最低部署目标 **iOS 17.0**，Bundle ID `com.hypo.clipboard.ios`。

然后 File › Add Package Dependencies › Add Local，选择 `shared/HypoiOS`，把 `HypoiOS` 库加入 app target。

- [ ] **Step 2: 写 Info.plist 的本地网络声明**

这两个键**必不可少**。缺了它们，Bonjour 发现会静默失效——不报错、不提示，只是永远发现不到设备。

在 target 的 Info 标签页添加：

| 键 | 类型 | 值 |
|---|---|---|
| `NSLocalNetworkUsageDescription` | String | `Hypo finds your other devices on this network to sync your clipboard directly, without going through the cloud.` |
| `NSBonjourServices` | Array of String | 单个元素：`_hypo._tcp` |

- [ ] **Step 3: 写入口**

`ios/Hypo/HypoApp.swift`：

```swift
import SwiftUI
import HypoiOS

@main
struct HypoApp: App {
    @State private var context = HypoiOSContext()

    var body: some Scene {
        WindowGroup {
            RootView(context: context, historyStore: context.historyStore)
        }
    }
}
```

删除 Xcode 生成的 `ContentView.swift`。

- [ ] **Step 4: 在模拟器上运行**

```bash
cd ios && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Hypo -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation build 2>&1 | tail -5
```

期望 `BUILD SUCCEEDED`。然后在 Xcode 里运行，或：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl boot "iPhone 17"
open -a Simulator
```

- [ ] **Step 5: 端到端验证清单**

逐条做，每条记录实际结果。**这是第 2 期唯一的真实验收**：

1. App 启动，三个 tab 都能打开，不崩溃
2. Settings 显示本机设备名——**确认不是 `localhost`**（这是 Task 6 显式传 `UIDevice.current.name` 要防的问题）
3. Settings 显示通知权限状态；首次启动应弹出授权请求
4. 首次进入会触发系统的「本地网络」权限弹窗——**同意，并记录弹窗是否真的出现**
5. Mac 端启动 Hypo（`./scripts/build-macos.sh`），在 Pair tab 请求配对码，在 Mac 上完成配对
6. 在 Mac 上复制一段文本 → **iOS 的 History 列表应出现该条目**
7. 在 iOS 上点 Paste 按钮发送 → **Mac 的历史应出现该条目**
8. 关掉 Mac 的 Wi-Fi 或让两端不在同一网段，重复第 6 步 → 应经云端 relay 仍然同步
9. 在 Settings 里拒绝本地网络权限（系统设置里关掉），重启 App，观察 LAN 是否失效而云端仍可用

**任何一条不通过都要如实记录，不要跳过。** 第 6、7 两条是第 2 期的核心目标，其余是边界条件。

- [ ] **Step 6: 提交**

```bash
git add ios
git commit -m "feat(ios): add the app shell and local network declarations"
```

**注意 `ios/` 下会有 Xcode 生成的用户级文件**（`xcuserdata/`、`*.xcworkspace/xcuserdata/`）。提交前检查 `git status`，若有则加进 `.gitignore` 而不是提交它们。

---


### 执行记录：Task 10 的实测结果

**工程是手写的，不是 Xcode 生成的。** 本机没有 XcodeGen 也没有 Tuist，装任何一个都会让每次构建（包括 CI）多一层工具链依赖，而这个 target 只有一个源文件和一个包引用。`ios/Hypo.xcodeproj/project.pbxproj` 与 `xcshareddata/xcschemes/Hypo.xcscheme` 直接入库，其余 Xcode 写的用户级文件按 `.gitignore` 里新增的 `ios/` 段落忽略。

**跑真实 app 抓到一个单元测试抓不到的 bug。** 启动后日志里每 30 秒出现：

```
⚠️ Health check: Advertising should be active but isn't. Restarting...
⚠️ Health check: WebSocket server should be running but isn't. Restarting...
```

`startHealthCheckTaskIfNeeded` 不认识 `LanRole`，在 `.clientOnly` 设备上会永远断言"广播应该开着"并反复调用 `activateLanServices()`。今天之所以无害，只是因为那个函数里有角色守卫会提前返回——这让它从 bug 变成陷阱：谁动了那两个守卫，iOS 就会开始监听，而没有任何测试会红。已修（三个判断都加上 `shouldServe`），并在模拟器上等过两个周期确认警告消失。

Task 6 的上下文测试等的是 500 毫秒，而健康检查的第一拍在 30 秒——**这个 bug 在单元测试的时间尺度之外**。

#### 端到端清单的实际完成情况

| # | 项 | 结果 |
|---|---|---|
| 1 | 三个 tab 都能打开，不崩溃 | ✅ 三个视图分别单独渲染截图确认 |
| 2 | 设备名不是 `localhost` | ✅ Settings 显示 `iPhone 17`；`device_name` 持久化值一致 |
| 3 | 通知权限状态与首次授权弹窗 | ✅ 弹窗出现 |
| 4 | 本地网络权限弹窗 | ⛔ **模拟器不适用**——iOS 模拟器不强制本地网络权限，这条只能在真机上验 |
| 5 | 与 Mac 配对 | ⛔ 未验证，需要人工 |
| 6 | Mac 复制 → iOS 收到 | ⛔ 未验证，需要人工 |
| 7 | iOS 发送 → Mac 收到 | ⛔ 未验证，需要人工 |
| 8 | 跨网段经云端 relay 同步 | ⛔ 未验证，需要人工 |
| 9 | 拒绝本地网络权限后的降级 | ⛔ 未验证，需要真机 |

**5–9 条为什么自动化不了**：`xcrun simctl` 没有点击命令（`idb` 未安装），而配对必须在 iOS 上点「Request pairing code」、再在 macOS 菜单栏 app 里输入配对码——两端都要真实的界面交互。用 computer-use 控制模拟器需要用户当场授权。第 1–3 条是靠"把单个视图临时设为根视图"重新构建后截图绕过点击验证的，配对流程绕不过去，因为它需要的是交互而不只是渲染。

**所以第 2 期的核心验收（第 6、7 条）尚未取得证据。** 代码路径已接通并有单元测试覆盖，但"Mac 复制的东西出现在 iPhone 上"这件事本身还没有被观测到。不要把前面那些绿当成这一条的证据。

**另记一条留给后续**：`ConnectionStatusProber` 的创建包在 `#if canImport(AppKit)` 里（`TransportManager.setHistoryViewModel`），所以 iOS 上永远不会启动，`connectionState` 不会更新。当前界面不显示连接状态，所以不阻塞第 2 期；等界面要显示连接状态时必须处理。



### 执行记录：两处「写了但没人用」

Task 10 收尾时复查发现两个组件按计划写完了、测试也绿了，但**没有任何调用方**。两处都不是笔误，是计划本身没有指定接线点，而验证方式恰好绕过了这个问题。

**一、`PasteButton` 没有出现在任何视图里。** Task 8 在四个视图之后附了 `UIPasteControl` 的封装，但没说它放在哪。于是 `sendText` 也没有任何调用点——**清单第 7 条（iOS 发送到 Mac）不是"未验证"，是根本无法触发**。已把它放进 History 页面的底部安全区，并在下方显示上一次发送的结果。

顺带修了尺寸：`UIViewRepresentable` 不实现 `sizeThatFits` 的话，SwiftUI 会把提议宽度整个给它，按钮会横跨整屏。

**二、`AppContainerStorageLocations` 从未被使用。** Task 3 的整个产出是死代码：它写在 HypoiOS 里，而 `StorageManager.shared` 在 HypoCore 里，默认参数是 `CachesStorageLocations()`，HypoCore 够不到 HypoiOS 的类型。**iOS 会在存储压力下清空 Caches——历史条目还在，它们指向的图片文件没了。** 这正是 Task 3 当初要避免的事，而 Task 3 的提交信息写的是"store blobs in Application Support, not Caches"。

已把类型搬进 HypoCore，`StorageManager` 的默认值改成 `PlatformStorageLocations.current()`（iOS 用 Application Support，其余仍用 Caches，老 macOS 装机不受影响）。

**为什么原来的测试没发现**：它断言的是 `AppContainerStorageLocations().imagesDirectory` 包含 "Application Support"——这在单例用着另一个实现的整段时间里一直是通过的。**测工厂函数返回什么，不等于测真正被使用的那个对象是什么。** 现在 `StorageManager` 暴露 `imagesDirectoryURL`，测试直接断言单例解析出的路径。

这两处共同的形状是：**一个组件有测试、有文档、编译得过，却没有接入产品路径**。单元测试天然测不出"没人调用我"。能发现它们的只有两件事——把整条链路从入口走一遍，以及在提交前问一句"谁调用它"。



### 执行记录：本地工具链比 CI 新，本地绿不等于 CI 绿

`SettingsView` 里这行在本机 Xcode 26.5 上编译通过，在 CI 的 `macos-15` runner 上直接失败：

```
error: non-sendable result type 'UNNotificationSettings' cannot be sent from
nonisolated context in call to instance method 'notificationSettings()'
```

`await UNUserNotificationCenter.current().notificationSettings()` 返回的是设置对象本身，它不是 `Sendable`。两个工具链对这件事的判定不同。

**没有用 `@preconcurrency import` 压掉。** 那只是把错误降级成警告，问题原样留在代码里。改成用完成回调 + `withCheckedContinuation`，在回调内部就把状态映射成字符串，**只有 `String` 跨越边界**——这样结论不依赖于谁来编译。

本机只装了一个 Xcode，无法本地复现 CI 的工具链。**因此 iOS 的编译结论以 CI 为准，本地绿只是必要条件。** 这也是本期第二次出现"验证手段本身有盲区"：上一次是 `xcodebuild` 吞掉测试失败，这一次是本地工具链比 CI 宽松。


## Task 11: CI 构建 app target

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: 在 ios-core-build job 末尾追加**

```yaml
      - name: Build the iOS app
        working-directory: ios
        run: |
          xcodebuild build \
            -scheme Hypo \
            -destination 'generic/platform=iOS Simulator' \
            -skipMacroValidation \
            CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` 是必要的：CI 上没有签名证书，而模拟器构建不需要签名。

- [ ] **Step 2: 校验、提交、推送、确认 CI 全绿**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML ok"
git add .github/workflows/ci.yml
git commit -m "ci: build the iOS app target"
PRE_PUSH_ANDROID=0 git push
gh run list --branch feat/ios-app --limit 3
```

---

## 第 2 期完成定义

1. `cd macos && swift test` → 56，一个不少
2. `cd shared/HypoCore && swift test` → 143，一个不少
3. HypoiOS 的测试在 iOS 模拟器上全绿
4. `ios` app target 能为模拟器构建
5. CI 五个 job 全绿，`ios-core-build` 中新增的三步（HypoiOS 构建、HypoiOS 测试、app 构建）均通过
6. **Task 10 Step 5 的第 6、7 条实测通过**——Mac 复制的内容出现在 iOS，iOS 发送的内容出现在 Mac
7. Settings 显示的设备名不是 `localhost`

**第 3 期（分享扩展、App Group、Keychain 共享）与第 4 期（APNs 后台落盘）需要付费 Apple Developer 账号，不在本期范围内。** 本期全部功能在免费账号 + 模拟器下可用。

---

## 第 2 期完成记录（2026-08-30）

分支 `feat/ios-app`，`c15ea9b..db3c290`，31 个提交。

### 完成定义逐条核对

| # | 条件 | 结果 |
|---|---|---|
| 1 | `cd macos && swift test` → 56 | ✅ 56 |
| 2 | `cd shared/HypoCore && swift test` → 143 | ✅ 143 |
| 3 | HypoiOS 测试在 iOS 模拟器全绿 | ✅ 27（本地与 CI 一致） |
| 4 | `ios` app target 能为模拟器构建 | ✅ |
| 5 | CI 五个 job 全绿，iOS job 新增三步通过 | ✅ run 33329440657 |
| 6 | **Task 10 第 6、7 条实测通过** | ❌ **未达成** |

**第 6 条没有达成，第 2 期因此不算完整交付。** 起初以为障碍是「没法点击界面」,后来用 XCUITest 把点击这件事解决了(见下),真正的墙才露出来:

**Swift 侧没有实现配对的应答方,iOS 与 macOS 根本无法配对。** 详见设计文档第 11 节。一句话:配对是一方出示码、另一方认领码,而 Swift 只实现了出示码的那一半;认领那半只有 Android 和 Windows 的 .NET harness 有。全仓库唯一构造 `PairingChallengeMessage` 的 Swift 代码在测试辅助函数里。

所以第 6、7 条不是「未验证」,是**当前代码不支持**。补齐是独立的一项工作,不在第 2 期计划内。

用 XCUITest 驱动界面后,配对流程本身在 iOS 这一侧已经跑通到能显示配对码——过程中修掉两个会让配对永远失败的 bug(`relayHint: nil`、配对码只在 `.displaying` 状态渲染)。缺的只是对端。

### 本期修掉的问题

按发现方式分类，因为这比按模块分类更有用：

**只有跑真实 app 才能发现的**
- 健康检查每 30 秒撤销 `.clientOnly` 角色（第一拍在 30 秒，单元测试等 500 毫秒）

**只有 CI 才能发现的**
- `UNNotificationSettings` 跨隔离边界：本机 Xcode 26.5 放行，CI 的 macos-15 拒绝

**靠质疑验证手段本身才能发现的**
- `xcodebuild` 在 Swift Testing 失败时报 `** TEST SUCCEEDED **` 并返回 0

**靠对挂死进程取栈才能发现的**
- `-[UIPasteboard string]` 阻塞主线程，且在无宿主 app 的测试包里永不返回

**靠问「谁调用它」才能发现的**
- `PasteButton` 没有接进任何视图——发送功能没有入口
- `AppContainerStorageLocations` 是死代码——iOS 图片仍存在可被系统清空的 Caches

**设计文档早已标记、一直没修的**
- `DeviceIdentity` 硬编码 `.macOS`，iPhone 向对端自称 Mac

后四类的共同点是：**单元测试全绿，且每一条都不是单元测试能覆盖的形状**。

### 已知未处理

- `ConnectionStatusProber` 的创建包在 `#if canImport(AppKit)` 里，iOS 上 `connectionState` 不会更新。当前界面不显示连接状态，第 3 期若要显示必须先处理。
- `swift test` 跑完不退出：`LanWebSocketTransport` 有个无人关闭的心跳任务吊着进程和监听端口。测试本身早已通过。属于 HypoCore 范畴，本期未动。
- HypoiOS 的 27 个测试在 CI 上耗时 211 秒，本地 1.2 秒。未查因，不影响正确性。


---

## 端到端验收的最终状态（2026-08-30）

第 6 条达成了。一个 Mac 上的独立进程复制的内容，出现在 iOS app 的历史列表里，用真实界面断言：

```
testPairsWithHarnessAndReceivesWhatItSends passed (29.233 seconds)
```

| # | 项 | 结果 |
|---|---|---|
| 1 | 界面可用、不崩溃 | ✅ XCUITest |
| 2 | 设备名不是 `localhost` | ✅ XCUITest |
| 3 | 通知授权 | ✅ XCUITest |
| 4 | 本地网络权限弹窗 | ⛔ 模拟器不强制，只能真机验 |
| 5 | 与独立对端配对 | ✅ 经真实 relay，设备入列并落盘 |
| **6** | **对端 → iOS 内容送达** | **✅ 真实界面断言** |
| 7 | iOS → 对端 | ❌ 见下 |
| 8 | 跨网段经 relay | ❌ relay 令牌两个平台都缺 |

### 靠什么做到的：`tools/HypoHarness`

对端不能是一个单元测试——必须有东西真的持有 socket、真的在 Bonjour 上广播、真的用一个设备 ID 应答。这个 harness 就是那个东西，对应 Windows 的 `windows/tools/Hypo.Harness`。

用法：

```bash
HYPO_CODE_FILE=/tmp/hypo-code.txt HYPO_DEVICE_NAME="Harness Mac" \
HYPO_SEND_TEXT="hello" swift run HypoHarness show
```

它出示配对码、监听 LAN、广播 Bonjour，并把收到的内容打印出来（`HYPO_RECEIVED_FILE` 可写进文件供自动化读取）。

### 它逼出来的 bug

**每一个都是单元测试全绿的情况下存在的**，且只有对着真实对端才会暴露：

| bug | 后果 |
|---|---|
| `NetService.dictionary(fromTXTRecord:)` 桥接崩溃 | **一发现对端就 SIGABRT**，真机上一看到 Mac 就挂 |
| LAN 拨号 URL 丢掉端口 | 所有拨号打到 80 端口，**iOS 永远连不上任何东西** |
| 入站帧只接在 server delegate 上 | iOS 从不监听，所以**能发不能收** |
| 设备 ID 大小写敏感比较 | 对端找不到该回哪条连接，内容被丢弃 |
| 配对后无人拨号 | 刚配上的设备要等一个不相干的发现事件 |
| 发现与配对两条同步路径互相拆连接 | 连上、identify、立刻断开 |
| session 在首次使用前公开 | 并发 disconnect 作废它，**建任务时 abort 整个 app** |
| `LanSyncTransport.send` 送不到也报成功 | 界面显示"已发送"而实际什么都没发生 |

### 第 7 条为什么没验成

iOS 读取**别的 app 写入**的剪贴板会弹系统授权框。自动化测试里那个弹窗拦住了 `readForegroundText()`，XCUITest 的中断监视器没能可靠地消掉它。发送逻辑本身有单元测试覆盖，卡住的是剪贴板读取这一步。

**这是自动化环境的限制，不等于产品缺陷**——真机上用户自己点一下"允许粘贴"就过了。但它没有被验证过，不要当成已验证。

### 第 8 条为什么没验成

`/Applications/Hypo.app` 里也没有 relay 令牌，所以 **macOS 同样连不上 relay**（`/health` 的 `connections` 为 0）。iOS 侧已经加了构建阶段注入。要恢复云端通道，macOS 需要在有 `.env` 的环境下重新构建。

### 遗留问题

- **对端连上就发的第一帧可能丢失**：设备在**发现**阶段就拨号，早于配对完成，所以第一帧可能在收方还没拿到密钥时到达，然后被静默丢弃、无人重试。用户再复制一次会成功。harness 因此改成周期重发。这是真实缺陷，未修。
- **329 MB 构建产物进了 git 历史**：`git add -A` 扫进了 `tools/HypoHarness/.build`。已从 HEAD 移除并补进 `.gitignore`，但历史和远端仍在。清理需要重写分支，会影响其他人，没有擅自做。


---

## 界面重做（2026-08-30，用户评审后）

用户的评价是"现在的设计反人性",要求对齐 Android。去读 `origin/main` 上的 Android 代码(本分支 fork 之后它又改过三次)之后,确认我做的界面有几处是自己发明的:

| 我做的 | Android 实际 |
|---|---|
| 三个 tab(History / Pair / Settings) | **没有 tab bar**。单屏 History,顶部一行「搜索框 + 连接状态图标 + 齿轮」,Settings 从齿轮推入,配对从 Settings 推入 |
| 大标题 "History" + 全局 Clear 按钮 | 两者都没有 |
| 配对页把「出示码」和「输入码」两半同时铺开 | 先选 `Show a code` / `Enter a code`,**只显示选中的那一半**,成功后独立成功页 |
| 只有配对码一种方式 | **LAN / Code 两种模式**,LAN 列出同网段设备,点一下就配对 |

全部已对齐。LAN 那一条需要 Swift 侧原本不存在的能力——它能接收 LAN 配对 challenge,但从来不能发出——补了 `WebSocketTransport.sendRaw` 与 `LanPairingCoordinator`。

### 发送触发方式的定稿

原先按"和 Android 一样,前台自动发送"实现,实测发现 **iOS 每次回到前台都会弹粘贴授权框**(截图为证)。Android 没有这个代价,iOS 有,这是平台规则。

改为:`hasStrings` 静默探测 → 有内容才显示 `UIPasteControl` → 用户点击时苹果豁免、不弹框。比 Android 多一次点击,换掉每次一个弹窗。已实测确认启动无弹窗、按钮按需出现。


### LAN 点击配对打通（2026-08-30）

```
testTappingANearbyDevicePairsWithIt passed (20.414 seconds)
```

在列表里点一下同网段的设备就完成配对,对端是 `tools/HypoHarness`——一个真实的独立进程。

这条路 Swift 侧原本不存在:它能**接收** LAN 配对 challenge,但从来不能**发出**。补齐过程中撞到四个问题,全部是"对端答了、发起方听不见":

| 问题 | 为什么难发现 |
|---|---|
| 客户端只处理二进制帧,**文本帧只打日志就丢** | ack 故意发成文本(注释:so Android can parse it as JSON string) |
| `onIncomingMessage` 只在**信封解码成功后**才触发 | 配对 ack 不可能是信封——它在双方有密钥之前就要送达 |
| 补的转发写在 `catch ... as DecodingError` 里 | **帧解码器抛的是 `TransportFrameError`**,分支永远进不去 |
| `startDiscovery()` 从 `onAppear` 无条件重置状态 | SwiftUI 会多次调用 onAppear,把进行中的配对冲回列表;`.failed` 也活不过两秒 |

前三个叠在一起的表现是一模一样的:harness 打印「Paired over LAN」,iOS 一动不动。每修掉一层才能看见下一层。第四个把前三个都掩盖了——界面回到列表,看起来像"点击没生效"。

**教训**:把错误做成会说话的。改成"没答复 / 答了但读不懂(附原文)"之后,一次运行就把范围从"整条链路"缩到了"接收侧",这是前面几轮反复试错换来的。


## 第 6、7 条同时通过（2026-08-30）

```
testPairsOverLanAndSyncsBothWays passed (22.814 seconds)
RECEIVED text: copied on the phone 7949C9FB
```

一个测试走完全程:LAN 列表里点一下配对 → harness 复制的内容出现在 iOS 历史里 → 手机上复制的内容送达 harness。对端是 `tools/HypoHarness`,一个真实的独立进程。

**改用 LAN 配对而不是配对码**,因为配对码一分钟就过期,而 app 冷启动加导航就要花掉大半;而且同一网段上本来就该点一下了事。

### 最后一个坑:重发会把发送入口关掉

harness 原本每 4 秒重发一次(为绕过更早的一个竞态)。每收到一条,app 就把它写进剪贴板——于是从 app 的角度看,剪贴板**永远是自己写的**,`hasTextWorthSending` 恒为 false,**发送按钮一直不出现**。

这不是 bug,是设计使然:不重复发送刚收到的东西。但它意味着**一个不停重发的对端会让另一端无法发送**。harness 改成发成功一次就停。

### 当前状态

| 清单项 | 结果 |
|---|---|
| 1–3 界面、设备名、通知 | ✅ XCUITest |
| 4 本地网络权限弹窗 | ⛔ 模拟器不强制,需真机 |
| 5 配对 | ✅ LAN 点击 + 配对码两条路 |
| **6 对端 → iOS** | **✅** |
| **7 iOS → 对端** | **✅** |
| 8 跨网段经 relay | ❌ `/Applications/Hypo.app` 缺 relay 令牌,macOS 需在有 `.env` 的环境重新构建 |


## 第 8 条:经 relay 的双向同步通过（2026-08-30）

`tools/HypoHarness relay` 是一个**没有 LAN 监听、不发 Bonjour 广播**的对端——所以 iOS 找不到本地路由,任何送达的东西都只能是经 hypo.fly.dev 来的。这正是 relay 存在的意义:两台看不见彼此的设备。

它不需要重装 `/Applications/Hypo.app`,所以验证第 8 条不用替换你在用的 Mac 客户端。

### 结果

| | 结果 |
|---|---|
| harness 用令牌连上 relay | ✅ `Connected to the relay.` |
| **经 relay 配对** | ✅ |
| **经 relay 双向同步** | ✅ `testSyncsThroughTheRelayWithNoLocalRoute passed (35.885 seconds)` |

挡在中间的是两个都不在产品里的问题:

**发送早于对方存好密钥。** 配对完成的时刻两边不同步:出示码的一方提交 ack 就认为好了,而认领方还要轮询 ack、校验、写密钥。第一条消息落在这个缝里会因为没有密钥被丢弃,而且无人重试。harness 改成发送前等 8 秒。**这是真实缺陷,已修**:`IncomingClipboardHandler` 收到解不开的消息时,如果原因是"还没有这台设备的密钥",会等一秒重试,最多六次,而不是直接丢弃。只对缺密钥这一种原因重试——其他失败是真失败,等待只会推迟报告。

修完之后 harness 里那个 8 秒等待就删掉了:对端配对完立刻发送,内容照样送达,`testSyncsThroughTheRelayWithNoLocalRoute` 依旧通过。这比留着等待更能说明问题被解决了。

**harness 用两个身份。** `CloudRelayDefaults` 的请求头和鉴权令牌都由它自己的 `DeviceIdentity()` 推导,而 harness 配对时用的是另一个 UUID——于是它以身份 A 握着 relay 连接、以身份 B 完成配对,发给 B 的消息在 relay 上找不到连接。这是 harness 自己的问题,不是 app 的:同一时刻 app 侧日志是 `✅ [DualSyncTransport] Cloud succeeded`,它确实发出去了。改成自己构造 relay 配置、用同一个 ID 和对应的 HMAC 令牌。

### 顺带修掉的 UI bug

配对成功页传的是 `deviceName: nil`,所以只显示 "Paired" 而不带设备名。用户看不出是和哪台设备配上的,自动化也无从断言。现在从 `statusMessage`(`"Paired with X"`)里取名字。这一处修完,**经 relay 的配对断言当场从红变绿**——之前它一直失败,原因不是配对没成功,而是界面没说是谁。


## 端到端清单最终状态（2026-08-30）

| # | 项 | 结果 |
|---|---|---|
| 1–3 | 界面可用、设备名不是 localhost、通知授权 | ✅ XCUITest |
| 4 | 本地网络权限弹窗 | ⛔ **模拟器不强制该权限,只能在真机上验** |
| 5 | 配对 | ✅ LAN 点击 + 配对码,均对真实独立对端 |
| 6 | 对端 → iOS 内容送达 | ✅ LAN 与 relay 两条路 |
| 7 | iOS → 对端内容送达 | ✅ LAN 与 relay 两条路 |
| 8 | 跨网段经 relay | ✅ 对端无监听无广播,只能走云端 |

第 4 条不是没做,是**模拟器上不存在**:iOS 模拟器不强制本地网络权限,那个系统弹窗只在真机上出现。装到 iPhone 上首次浏览 Bonjour 时就会看到。

不过这一条里**真正会坏的部分是可以守住的**。缺了 `NSLocalNetworkUsageDescription` 或 `NSBonjourServices`,iOS 会拒绝 Bonjour 且**不报错、不弹窗、不留日志**——设备就是永远不出现,看上去像网络故障而不是缺声明。`scripts/check-ios-local-network.sh` 检查构建产物里这两个键,CI 在构建 app 之后跑它。已双向验证:两个键任缺其一都会判红。

弹窗本身仍然只能真机验。

测试规模:HypoCore 158、macOS 56、iOS 30 单元 + 11 UI。


## Android 与 Swift 之间的时间戳不兼容（2026-08-31）

用户用真机 Android 配对 iOS 时报「The data couldn't be read because it isn't in the correct format.」。查下来是一处两端的格式分歧:

- Android 写时间戳用 `clock.instant().toString()`,Java 的 `Instant.toString()` **在小数秒非零时会带上小数秒**——也就是几乎总是带。
- Swift 侧读时间戳用的是裸的 `ISO8601DateFormatter()` 和 `JSONDecoder.dateDecodingStrategy = .iso8601`,**两者都不接受小数秒**,遇到就返回 nil / 抛 `DecodingError`。

涉及 `PairingPayload` 的 `issued_at`/`expires_at`、`PairingAckPayload` 的 `issued_at`,以及走 `PairingSession` 解码器的 `PairingChallengePayload.timestamp`——**配对握手里的每一个时间戳**。

修法是解析时同时接受带与不带小数秒两种写法,写出时仍不带(各平台都读得了)。`PairingDateFormat` 收口这件事,四个用例钉住:读 Android 的格式、读不带小数的、自己写的能自己读、垃圾仍然被拒。

**为什么之前没被发现**:macOS↔macOS 和 Swift↔Swift 的往返测试两端都是 Swift,写出的都不带小数秒,所以永远走不到那条分支。只有真的接上 Android 才会踩到。

**注意**:这不一定是用户看到的那一条错误的成因——`PairingChallengePayload` 解码失败会显示 "Unable to decode pairing challenge",不是那句话。所以另外把 `PairingRelayClient` 里四处裸解码也包上了说明,现在任何一处失败都会指出是哪一步、收到了什么。用户复现时那条消息会直接指认位置。


## 列表样式与配对卡死（2026-08-31,用户真机反馈）

### 「Pairing with OPPO PLP110...」永远不动

`LanPairingCoordinator` 只给"等 ack"加了 30 秒上限,**没有给整个流程加**。而 `WebSocketTransport.connect()` 本身可以永远挂着——一台广播了服务却不接受连接的设备就会造成这个。界面于是停在「Pairing with …」,既不成功也不失败,也没有退路。

改成整个配对流程一起限时,超时报「That device did not respond in time」。

### 列表样式没有参考 Android

原来是 `List` 里两行纯文本。Android 是卡片:

| 元素 | Android | 现在的 iOS |
|---|---|---|
| 容器 | Card,`surfaceVariant` 底色,点击即复制 | 圆角卡片,`secondarySystemBackground`,点击即复制 |
| 第一行 | 类型图标 + 来源徽章 + 时间戳 | 同 |
| 来源徽章 | 加密盾牌、云图标(仅云端)、设备名;本机用 `primaryContainer` | 同,本机用强调色 |
| 第二行 | 预览文字 | 同,最多三行 |

"仅云端才显示图标、LAN 不显示"这一条是照抄 Android 的注释("no icon for LAN, matching macOS")——常见路径不该被装饰。

### 顺带发现:前台复制时按钮不出现

`refreshClipboardOffer()` 原本只在**切回前台**时跑一次。在 app 已经在前台时复制东西(分屏、分享面板回来),按钮不会出现,要切出去再切回来才行。改成界面可见时每 1.5 秒探测一次——`hasStrings` 不弹框、不泄露内容,剪贴板管理器本来就是这么做的。

这一条是测试逼出来的:测试重设剪贴板后没有再切前台,于是暴露了只在前台切换时刷新的缺口。


## 删除已配对设备,以及两个把我骗过的坑（2026-08-31）

用户反馈「OPPO 显示离线且无法删除」。两件都是真的。

### 「离线」是真话但没用

`isOnline` 只有在**建立过连接之后**才会变真。一台就在同一网络上、Bonjour 已经发现了的设备,在从未通信过之前一律显示 Offline——技术上没错,信息量为零。改成三档:已连接 / 在本网络上(Bonjour 见得到)/ 不可达。

### 删除功能此前根本不存在

Android 的 `removeDevice` 是四步,其中**先删密钥再忘掉设备**这个顺序是有道理的:留着一台没有密钥的设备,它解不开任何发给它的东西,看起来像个坏掉的对端而不是一台被移除的设备。iOS 侧照此实现,并从 `SettingsView` 挪到 `HypoiOSContext.unpair`,用容器自己的 key provider——原来的写法是现场 `KeychainDeviceKeyProvider()` new 一个,配置一旦分叉就会删错条目。

### 坑一:UI 测试跳过 ≠ 通过

给删除写的 UI 测试第一次跑出来是 **skipped**(模拟器上恰好没有已配对设备)。**跳过的测试等于没测**,而它当时看起来像是绿的。改为在 `HypoiOSTests` 里用单元测试钉住三条:设备不再列出、密钥一并消失、删一台不影响另一台。UI 测试保留为机会性检查。

### 坑二:增量构建用了陈旧模块,让已修好的代码看起来没修

`UserNotificationScheduler` 的 `center` 默认参数是 `.current()`,而 `UNUserNotificationCenter.current()` 在没有 app bundle 的 xctest 宿主里会抛 ObjC 断言——不是 Swift 能 catch 的那种,整个测试进程当场死掉,**0 个测试运行**。

之前我以为已经处理过:参数确实改成了可选。但**默认值仍是 `.current()`**,而默认参数在每一个省略它的调用点都会求值,包括 `HypoiOSContext()`。原来那条注释("默认参数只在 app 真正构建时求值")是错的。

改成默认 nil、用到时才解析,且只在 `Bundle.main` 确实是 `.app` 时才取。

**但修完之后崩溃依旧**,栈顶仍指向默认参数生成器。源码是对的,是 `xcodebuild` 的增量产物没更新——`rm -rf DerivedData/HypoiOS-*` 之后 33 个测试全绿。**症状是"修复没生效",实际是"验证读的是旧二进制"**,这是本期第三次撞上"验证手段本身有盲区"。


## 端到端验证真的跑起来了（2026-08-31）

在此之前有四个 UI 测试一直是 **skipped**,而汇总行看起来是绿的。跳过的测试证明不了任何事,所以把真实对端起起来让它们真跑。

### 结果

| 测试 | 结果 |
|---|---|
| `testPairsOverLanAndSyncsBothWays` | **通过** —— LAN 配对 + 双向同步 |
| `testTappingANearbyDevicePairsWithIt` | **通过**(需全新对端身份,见下) |
| `testAPairedDeviceCanBeUnpaired` | 仍 skip;行为已由 `UnpairTests` 三个单测覆盖 |
| `testSyncsThroughTheRelayWithNoLocalRoute` | **通过** —— 经中转服务器配对 + 双向同步 |

`testPairsOverLanAndSyncsBothWays` 通过意味着最初验收清单里的第 6、7 条(Mac→iOS、iOS→Mac)真的成立了。

### 两次失败都是我起 harness 的方式不对,不是产品问题

第一次两个方向都红。查 harness 日志发现:

```
[incoming] 📥 Received clipboard: text from iPhone 17
[HistoryStore] ✅ Inserted entry: copied on the phone 5C476580
```

**iOS → harness 明明成功了**,但测试断言"从未到达"。原因是 harness 只有在设了 `HYPO_RECEIVED_FILE` 时才把收到的内容写盘供测试轮询;同样,只有设了 `HYPO_SEND_TEXT` 才会主动发送。两个变量我都漏了,于是"没发过"和"发到了但没人记录"被一起读成了"同步坏了"。

正确的起法:

```bash
HYPO_DEVICE_NAME="Harness Mac" HYPO_LAN_PORT=7011 \
HYPO_SEND_TEXT="hello from the Mac harness" \
HYPO_RECEIVED_FILE=/tmp/hypo-received.txt \
swift run HypoHarness show
```

`HYPO_LAN_PORT` 必须换:默认 7010 被本机运行中的 Hypo.app 占着。

### 已配对的设备不能再配一次

`testTappingANearbyDevicePairsWithIt` 在同一轮里跑第二次会失败,因为 iPhone 已经和这个 harness 配过了,重复的 challenge 会被 `PairingSession` 判为 duplicate 拒掉。换一个全新身份的 harness(每次启动都会生成新的 device id)即通过。这是正确行为,但意味着**这个测试对运行顺序敏感**。


### relay 模式的两个前置条件

1. **`RELAY_WS_AUTH_TOKEN` 必须传给 harness**,否则中转服务器回 401,harness 连不上、也就永远不会生成配对码,测试只会看到"没有配对码"然后 skip。取自仓库根的 `.env`。
2. **`HYPO_CODE_FILE`** 要设,harness 才会把配对码写盘给测试读。

完整起法:

```bash
RELAY_WS_AUTH_TOKEN="$(grep -m1 '^RELAY_WS_AUTH_TOKEN=' .env | cut -d= -f2-)" \
HYPO_DEVICE_NAME="Relay Harness" HYPO_LAN_PORT=7012 \
HYPO_CODE_FILE=/tmp/hypo-code.txt HYPO_RECEIVED_FILE=/tmp/hypo-received.txt \
HYPO_SEND_TEXT="hello over the relay" \
swift run HypoHarness relay
```

### 发送按钮的等待必须能重试

`RelaySyncTests` 第一次失败在"没有出现发送按钮",而它上一行的断言(relay → 手机的内容已到达)是通过的。原因和 `HypoUITests` 里那个一样:**任何活跃对端推送的每一条内容都会被写进剪贴板**,此后 app 正确地认为没有用户的新内容可发。一次性等待会输掉这场竞争,必须边重设剪贴板边多次采样。


## 合并设备列表,以及补上 Android 的条目预览（2026-08-31）

### Devices 一处显示全部

原来要走「Settings → Devices → Pair a device → LAN 标签页」才能看到附近设备。那一区本来就是讲设备的,而看得见的设备是最短的配对路径,不该藏在二级页面加一个模式切换后面。现在:

- 已配对设备(带状态,左滑 Unpair)
- **本网络上发现的、尚未配对的设备**(点一下即配对)
- 最下面 **Pair with code**,给互相看不见的设备兜底

配对页因此只剩输码一条路,模式切换整个去掉了。

### 条目预览

Android 的历史卡片在内容被截断、或条目是图片/文件时,提供一个入口打开详情表单:完整图片或**可选中的完整文本**,加上 Save / Open。iOS 侧照做:

| | Android | iOS |
|---|---|---|
| 何时出现入口 | 截断的文本,以及所有图片/文件 | 同 |
| 文本 | 可选中、可滚动 | 同(`.textSelection(.enabled)`) |
| 图片 | 完整渲染 | 同 |
| Save / Open | 两个按钮 | 一个分享面板(iOS 上它同时提供存到相册和用其他 app 打开) |

图片走分享面板时先写到临时文件再交给 `ShareLink`——直接给 Data 只会提供"分享字节",给 URL 才会出现"存储图像"。

### 嵌套按钮不可靠

预览入口第一版做成了整行 Button 里面再套一个 Button,测试点不到它。**SwiftUI 不保证把点击投递给嵌套在另一个按钮里的按钮**——这不是测试的问题,真机上同样点不到。改成外层用 `.contentShape` + `.onTapGesture` 负责"点击即复制",内层保持真正的 Button。

### 三个共享测试辅助

改导航时同一类失败重复出现了三次,提成共享函数:

- `revealElement` —— **SwiftUI 的 List 不会把屏幕外的行放进可访问性树**,所以被挤到折叠线以下的行报的是"不存在",不是"看不见"。Devices 区变长后 `Pair with code` 就落到了那里。
- `waitForSendControl` —— 活跃对端推送的每一条都会被写进剪贴板,此后 app 正确地认为没有用户的新内容可发。一次性等待会输掉这场竞争。
- `isPaired` —— 可访问性标识符在不同 SwiftUI 布局下会落到 cell、staticText 或 button 上,且随外层视图变化。三个都问一遍,比钉死其中一个可靠。


### 又一次:本机工具链比 CI 宽松

提出去的三个共享测试辅助是文件级函数,它们访问 `XCUIApplication` 的成员——那些成员是 MainActor 隔离的。本机 Xcode 26.5 编译通过,CI 直接报错:

```
error: main actor-isolated property 'staticTexts' can not be referenced from a nonisolated autoclosure
```

修法是给三个函数和 `HypoUITests` 类都标上 `@MainActor`(另外三个测试类本来就标了,只有这个漏了)。这样在两个工具链下都成立,不依赖谁更宽松。

**这是本期第二次因为同一个原因被 CI 拦下**(第一次是 `UNNotificationSettings` 跨隔离边界)。结论没变:**本机只装了一个 Xcode,iOS 的编译结论必须以 CI 为准,本地绿只是必要条件。**


## CI 的 iOS job 卡死,以及把工具链对齐（2026-08-31）

「Run HypoCore tests on iOS Simulator」这一步连续两轮跑了近一小时,而它平时只要几分钟。排查结果:

- **不是最后那个提交**:它只改了 `HypoUITests.swift` 和文档,`git diff de32b69 9c999e2 -- shared/HypoCore` 是空的。
- **不是缓存**:DerivedData 缓存在 macOS Tests 那个 job,iOS job 没有缓存。
- **不是 relay 测试**:那个测试由 `HYPO_RELAY_TESTS` 控制,CI 没设。
- **本地不复现**:同一条命令本地 66 秒跑完,136 个测试通过。

所以是 runner 环境本身卡住了。

顺带解决了另一件被反复付学费的事:**CI 的 `macos-15` 镜像装的是 Xcode 16.4(Swift 6.1),本机是 Xcode 26.6(Swift 6.3.3),差了两个大版本。** 本期两次被 CI 拦下的编译错误(`UNNotificationSettings` 跨隔离边界、共享测试辅助的 actor 隔离)都是这个差距造成的——新编译器接受,旧的拒绝。本地无法复现,因为**本地那个更宽松**;实测把 `@MainActor` 去掉后本地干净构建照样通过。

改成 `runs-on: macos-26`,两边同代。代价是不再对旧 SDK 做兼容性验证,而这个 app 的部署目标是 iOS 17+,可以接受。

另外给三个 iOS 步骤加了单步超时(20/20/30 分钟)。**卡死本身不可怕,可怕的是它烧满整个 job 预算却不说停在哪一步。**


### 写死模拟器机型是个脆弱点

换到 `macos-26` 后那一步立刻以 70 退出,日志列出了可用目标:该镜像上**根本没有名为「iPhone 16」的设备**,只有 iPhone 17 系列和 iPhone Air。而 workflow 和 `run-ios-tests.sh` 都把机型写死成了 `iPhone 16`。

值得注意的是本机也没有 iPhone 16 —— 我一直手动传 `iPhone 17`,所以这个坑在本地从来不会暴露。

改成两边都动态解析:取镜像上实际可用的任一 iPhone,指定的机型不存在时打印一行说明再退回。这些是单元测试和 UI 测试,不依赖具体机型。

另外注意"设备类型"和"设备"是两回事:`simctl list devicetypes` 里有 iPhone 16,但 `simctl list devices available` 里没有对应实例。诊断步骤原来打印的是前者,所以看起来一切正常——现在改成打印后者。


### 升级运行器立刻兑现了一条早就写下的预言

模拟器解析修好之后,那一步换了个原因失败:

```
nw_listener_socket_inbox_create_socket setsockopt SO_NECP_LISTENUUID failed
✘ Test "an entry sent over LAN lands in the receiver's history" failed
```

这正是第 1 期处理过的问题——**iOS 的测试包不能创建 `NWListener`**。当时我为此把 `LanWebSocketServerTests` 和两个 `TransportManagerLanTests` 标为 macOS 专属,并在注释里写下:「iOS 18.5(CI 的模拟器)不强制执行这一点,所以直到本地装了 Xcode 26.6 / iOS 26.5 才发现。」

`LanClipboardSyncTests` 当时漏掉了,而 CI 一直跑在 iOS 18.5 上,所以一直是绿的。**换到 macos-26 的第一件事就是让那条注释应验。**

从设计上说它本来也不该在 iOS 上跑:它在进程内绑定了一个服务端,而 **iOS 按设计永远不当服务端**。iOS 真正扮演的角色——主动拨号——由 app 自己的 UI 测试对着真实对端覆盖。

iOS 131(减去 5 个 macOS 专属),macOS 162 不变。


### `HarnessSyncTests` 必须独享一个新起的 harness

和别的配对测试一起跑时它会失败在「the harness's clipboard entry never arrived」。原因不在产品,在测试对端:

**harness 只发送一次。** 这是有意的,它自己的注释写着理由——重复发送会让手机的剪贴板永远是"刚收到的那条",于是 app 正确地认为没有用户的新内容可发,**发送按钮再也不出现**,把依赖它的那批测试全部打挂。

所以哪个测试先配对上,那条消息就被谁消费掉;后面的测试等不到任何东西。加上"已配对的设备不能再配一次"(重复 challenge 会被判为 duplicate),这个套件对运行顺序是双重敏感的。

正确跑法:

```bash
pkill -9 -f HypoHarness; rm -f /tmp/hypo-received.txt
HYPO_DEVICE_NAME="Harness Mac" HYPO_LAN_PORT=7011 \
HYPO_RECEIVED_FILE=/tmp/hypo-received.txt \
HYPO_SEND_TEXT="hello from the Mac harness" \
swift run HypoHarness show &
# 然后单独跑：-only-testing:HypoUITests/HarnessSyncTests
```

失败信息现在会把这件事说出来,免得下次又去查产品。


## 依赖真实对端的测试改为显式开关（2026-08-31）

CI 上 `Build and UI-test the iOS app` 失败在「Failed to launch」——模拟器偶发的启动故障。但更根本的问题是:**那几个测试在 CI 上永远没有对端**,它们启动 app 只是为了跳过,花掉几分钟、什么也没验证,还多给了模拟器一次失败的机会。

改成在**启动任何东西之前**先检查标记文件 `/tmp/hypo-peer-tests`。

### 为什么用文件而不是环境变量

先试了 `HYPO_PEER_TESTS=1`——**`xcodebuild` 不会把 shell 的环境变量传给测试运行进程**,测试读到的是空。再试 `TEST_RUNNER_HYPO_PEER_TESTS=1`(文档说这个前缀会传给 UI 测试运行器)——**同样没到**。文件两边都看得见,不需要任何机制配合,CI 上也永远不会有。

### 效果

| | CI 形态(无标记) | 本地(有标记 + harness) |
|---|---|---|
| 结果 | 16 个测试,4 跳过,**0 失败** | 依赖对端的测试真跑并通过 |
| 耗时 | **166 秒**(原 342 秒) | — |

跳过从"启动 app、等待、超时"变成零点几秒。

### 本地跑完整闭环

```bash
pkill -9 -f HypoHarness; rm -f /tmp/hypo-received.txt
cd tools/HypoHarness && HYPO_DEVICE_NAME="Harness Mac" HYPO_LAN_PORT=7011 \
  HYPO_RECEIVED_FILE=/tmp/hypo-received.txt \
  HYPO_SEND_TEXT="hello from the Mac harness" swift run HypoHarness show &
touch /tmp/hypo-peer-tests
# 单独跑，不要和别的配对测试混在一起（见上文 harness 只发送一次）
cd ios && xcodebuild test -scheme Hypo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:HypoUITests/HarnessSyncTests
```

这也落实了一条分工:**iOS 的开发闭环在本地,CI 只做最后一道关。** 本地能跑 iOS 的每一样东西,一轮 66 秒;把 CI 当诊断工具是在为本地就能抓到的东西反复付 push-and-wait 的代价。CI 剩下的实际价值是两条:一个干净的受限环境(今天的 `SO_NECP_LISTENUUID` 就是同样 iOS 26.5 下 CI 失败、本地通过),以及另外四个平台。


## 界面细节（2026-08-31,用户逐条指出）

### app 图标从来没做过

`ios/` 下没有 `Assets.xcassets`,工程里 `ASSETCATALOG_COMPILER_APPICON_NAME` 是空字符串,构建产物里一个图标文件也没有——所以主屏上是空白默认图标。不是"坏了",是缺失。

从 macOS 的 `AppIcon.icns` 抽出 1024×1024(已确认无 alpha 通道,iOS 不接受带 alpha 的图标),建资源目录并接进 Resources 阶段。

### 设备列表里每一行都写着 "Unknown"

那一行显示 `device.platform`,而**三处构造 `PairedDevice` 全都写死成 "Unknown"**,其中一处的注释还写着"从 device ID 探测平台",探测从没实现。

查了为什么:**配对协议里根本不传平台**。`PairingChallengeMessage` 只有 id、设备名、公钥、nonce、密文、tag,Android 的模型一模一样;Bonjour 的 TXT 记录也没有平台字段。这个信息两端都不存在。

Android 的设备行显示的是名字 + 状态徽章 + 地址/最后可见时间,**没有平台**。改成同样的做法。要真正显示平台需要改配对协议加字段,两端同时改,是另一件事。

### history 底部的白边

`.safeAreaInset(edge: .bottom)` 里的容器**无条件存在**,带着 `.padding(.vertical, 8)` 和 `.bar` 背景。没东西可发时它就是一条空白材质条,而 settings 没有这个 inset 所以是满屏——两个页面因此对不齐。改成只在真有内容时才插入。

### Paste 按钮不能换成别的图标

实测 `UIPasteControl.Configuration` 只有五个属性:显示模式、圆角样式、圆角半径、前景色、背景色。**没有任何设置自定义图片的接口**,四个显示模式(图标+文字/仅图标/仅文字/箭头+文字)都用系统自己的粘贴字形。

原因不难理解:正是这个系统绘制的控件才享有"读剪贴板不弹框"的豁免,换成自绘按钮就等于放弃豁免。

能做的是改成**仅图标 + 胶囊形**。改的时候发现文件里有一行遗留的 `displayMode = .labelOnly` 排在后面把设置覆盖了。

### 图片条目显示尺寸

新增 `listDescription`,图片显示"262×138 · PNG · 19 kB"。没有改共享的 `previewDescription`——macOS 也在用它,而且搜索是按它匹配的。

### 连接状态改成图标

照搬 macOS 菜单栏的映射:断开 `cloud.slash.fill` 灰、连接中 `arrow.triangle.2.circlepath` 橙、LAN `wifi` 绿、云端 `cloud.fill` 蓝、错误 `exclamationmark.triangle.fill` 红,文案也统一成同样的词。

顺带发现 `testReportsConnectionStatus` **只打印、不断言**——无论 app 显示什么(包括什么都不显示)它都通过。改成断言状态行确实显示了已知状态之一。


## 设备可以改名（2026-08-31）

设备名默认取自操作系统对机器的称呼,而**这个名字是每个对端看到的名字**,三个平台都没有改名入口。`DeviceIdentity.deviceName` 是 `let`,也没有任何 setter。

改成 `private(set) var` 加一个 `rename(to:)`:写回 UserDefaults、拒绝空白、照初次命名的规则去掉 `.local`。五个单元测试钉住:改名生效、重启后仍在、空白被拒、`.local` 被剥离、**device id 不变**(对端的密钥是按 id 存的,改了就等于解除配对)。

界面上那一行变成可编辑,并带一个清除按钮——不加的话要先选中旧名字,在手机上很别扭,而且测试正是在这里反复把新名字**追加**到旧名字后面("Renamed 129ARenamed F59F")。

### 找 bug 找了半天,bug 在测试里

`testAppPairsWithASwiftPeer` 配对后断言不到对端,连查五轮都失败。最后从模拟器容器里把 `transport_paired_devices` 解出来:

```
count: 6
 - UITest Peer | Unknown | 4eee26da
 - Harness Mac | Unknown | cb077930
 - derek's MacBook Air (2) | ...
```

**对端就在里面,而且排第一。产品从头到尾都是对的。** 一路上我改错了三次断言方式,每次都以为是产品问题:

1. 以为行在屏幕外 —— 加滚动,仍失败
2. 以为 `accessibilityIdentifier` 把整行合并了 —— 加 `.contain`,仍失败
3. 以为成功页文案是 "Paired" —— 实际是 **"Paired with UITest Peer"**

第 3 条是把屏幕内容**写进文件**才看到的:`xcodebuild` 会吞掉测试进程的 `print`,而 attachment 只进 xcresult。harness 早就在用文件通信,我却绕了一大圈才想起来用同样的办法。

最后一次失败则是等待窗口不够:中转服务器往返时间会波动,30 秒偶尔不够,放宽到 120 秒后 16.5 秒就通过了——快的时候立即返回,不增加耗时。

**教训**:断言失败先问"我断言的东西是否存在",再问"产品是否有问题"。这一轮五次失败全部属于前者。


## 按 Android 的真实报文格式测试（2026-08-31）

真机互传这条缺口没有手机就关不掉,但能收窄到只剩"设备本身"这一项:**用手工拼出的、符合 Android 序列化规则的字节去跑配对**。

原有的配对测试用 Swift 自己的编码器造 challenge,两端**按构造就一致**,Android 写出来的差异根本没机会出现——小数秒那个 bug 就是这么活下来的。

`AndroidWireFormatTests` 里的报文按 Android 的规则手写:

| 规则 | 体现 |
|---|---|
| `@SerialName` 蛇形键名 | `initiator_device_id` 等 |
| `encodeDefaults = false` | **不写 `challenge_id`**(它有默认值) |
| `Base64.NO_WRAP` | 带 padding 的标准 base64 |
| `Instant.toString()` | 纳秒 / 毫秒 / 无小数三种形态 |
| `challenge` 是 String | 密文内的 payload 用 base64 字符串,不是 Swift 的 `Data` |

四个测试:三种时间戳形态各一,外加"缺 `challenge_id` 仍能解码"。

### 确认它们真的抓得住 bug

**一个抓不住 bug 的回归测试没有价值。** 临时把 `PairingDateFormat` 的小数秒支持撤掉,三个时间戳测试立刻变红,失败原因正是「Unable to decode pairing challenge」;恢复后全绿。

### 过程中的一次误判

第一版四条全红,包括本该通过的"整秒"。看错误原因是「Challenge timestamp is outside the allowed window」——**时间戳其实解析成功了**(否则会是"无法解码"),是我 fixture 里写死的时间和 session 的时钟对不上。改成从同一个时钟派生即可。

这反过来也是证据:窗口检查能报出来,说明解析这一步已经过了。

HypoCore 从 170 涨到 174。


## 同名设备会互相顶掉（2026-08-31）

查配对测试时顺手发现的真 bug,影响真实用户。

`registerPairedDevice` 找不到相同 id 时,会退回**按"名字 + 平台"**匹配并覆盖。而平台永远是 "Unknown"(见上文:协议里根本不传),所以这条实际退化成**只按名字匹配**——配对第二台叫 "iPhone" 的设备,会**静默顶掉**第一台。第一台仍列在那里,但 id 已经是别人的,于是不声不响地停止同步。

这个回退的本意应该是"同一台设备重装后换了新 id,别留重复条目"。但两害相权:**重复条目只是碍眼,而且现在能手动删除;一台无缘无故不再同步的设备不是。**

修法是在平台确实已知时才做这个回退。今天等于禁用了它,但意图留在代码里——哪天协议真的开始传平台,它自己就恢复。

三个测试:同名两台都保留、同 id 重复注册是更新而非新增、平台已知时仍会合并。**去掉守卫后第一个立刻变红**(`count → 1`),确认它抓得住。

### 还原备份时又踩了相对路径

验证"测试能抓住 bug"之后要把守卫加回去,我写的是 `cp "$S/tm.bak" shared/HypoCore/Sources/...` —— 而同一条命令前面有 `cd` 到了 `shared/HypoCore`,相对路径于是解析到不存在的位置,**`cp` 失败了,而我用 `2>/dev/null` 把错误吞掉**。接着 `git diff --stat` 显示有改动(那是别的文件),看起来像成功。

直到跑全量才发现 177 个测试里红了一个——正是我刚"还原"的那个守卫。

记忆里明确写过这条:**链式命令里 `cd` 之后不要用相对路径**。这次是自己吞掉了唯一会告诉我出错的信号。


## nearby 里看不到 OPPO:一个状态机把两件事揉在了一起（2026-09-01）

用户反馈 OPPO 不在 nearby 列表里。查日志,**它明明在被发现**:

```
🔍 Peer discovered: OPPO PLP110 at 10.0.0.17:7010, device_id=bbe296d6-…
```

而且从容器里解出来看,它当时**不在**已配对列表(所以不是被"已配对"过滤掉的)。

真正的原因在 `LanPairingViewModel`:它把**设备列表**和**配对进度**塞进同一个 `state` 枚举,于是有两个冻结点:

```swift
// 轮询里
case .pairing, .paired: break     // ← 不再刷新列表
// pair(with:) 里
guard case .found = state else { return }   // ← 点击直接无效
```

用户之前点过 OPPO 且卡住过。状态一旦停在 `.pairing` / `.paired` / `.failed`,**列表就再也不更新,那台设备也再也点不动**,而界面什么都不说。

补丁盖不住这个——拆开才对:`peers` 始终刷新,`pairing` 只表示最近一次尝试的结果,并且可以关掉。一台设备出现在网络上,和上一次尝试成功与否本来就没有关系。

### 测试第一版没抓住这个 bug

写了"失败后仍可再次点击"的测试,把冻结逻辑装回去,**5 个测试照样全绿**。

原因是测试替身抛的是 `CancellationError`,而 view model 把取消当作"没发生过"、会把 `pairing` 置回 nil——所以第二次点击本来就会放行。**那不是在测失败,是在测取消。** 换成普通错误后,装回冻结逻辑立刻红:`attempts → 1` 而不是 2。

**教训**:验证"测试能抓住 bug"时,要确认走的是同一条代码路径。类型选错,验证本身就是假的。

### 顺带:状态框太大

`LabeledContent` 里套 `Label` 会按默认字号和间距渲染。改成 `HStack` + 小号图标 + 次要色文字。


## macOS ↔ iOS 的真实互传,验证通过（2026-09-01）

此前一直把"真机互传"整块记为未验证,这说得过于保守了。**对端是 macOS 时,产品对产品的双向同步现在验过了**,而且对面不是 harness,是用户自己运行的 Hypo.app。

### Mac → iPhone

在 Mac 上 `pbcopy` 一段带时间戳的文字,十几秒后模拟器的日志:

```
📥 Cloud relay incoming message received: 0.75 KB, origin=cloud
📦 Decoded envelope: deviceId=007e4a95, deviceName=derek's MacBook Air (2)
📥 Received clipboard: text from derek's MacBook Air (2)
✅ Applied text to clipboard (25 chars)
```

25 个字符正是发出的那句。

### iPhone → Mac

先把 Mac 的剪贴板换成别的内容,再让 UI 测试在模拟器上点 Paste。测试结束后 `pbpaste` 拿到的正是 iOS 发出的文本。

### 所以真正剩下的缺口比之前说的窄

| 项 | 状态 |
|---|---|
| macOS ↔ iOS(真实产品) | **已验证** |
| Android ↔ iOS(OPPO) | 未验证 —— `dns-sd` 显示手机当前不在网络上(息屏或未运行) |
| 物理 iOS 设备 | 未验证 —— 全程模拟器 |
| 本地网络权限弹窗/拒绝 | 无法验证 —— 模拟器不建模该权限 |

第二项的**报文格式**部分已由 `AndroidWireFormatTests` 覆盖(按 Android 的序列化规则手写、并验证过能抓住时间戳 bug),缺的只是那台设备本身。


### 让 Android 那条在设备出现时自动完成

`testTappingANearbyDevicePairsWithIt` 改成从 `/tmp/hypo-peer-name` 读取目标设备名(默认仍是 Harness Mac),所以同一个测试可以对准真手机。

配套一个监视脚本 `scratchpad/await-oppo.sh`:每 45 秒用 `dns-sd -B _hypo._tcp local` 扫一次,发现 OPPO 或 Xiaomi 就写入目标名、放上开关文件、跑那个测试。**手机端不需要任何操作,配对是模拟器这边发起的**,人只要把手机唤醒、确认 Hypo 在运行。

这样这条缺口不再是"等人有空",而是"设备一上线就自证"。


## 模拟器和 Mac 共用剪贴板,这会伪造证据（2026-09-01）

用户问:历史里那条在 Mac 上复制的链接,为什么标着来自 iPhone 17 而不是 Mac?

实测:

```
Mac clipboard:  host-to-sim probe 113645
Sim clipboard:  host-to-sim probe 113645
```

**模拟器默认开启「自动同步剪贴板」**,Mac 上复制的内容会直接进入模拟器剪贴板,**完全不经过 Hypo**。于是链路变成:Mac 复制 → 模拟器剪贴板自动拿到 → Hypo 认为"有外来内容可发" → 测试点 Paste → 记成**本机发出**的条目。

### 这让我此前的一个验证结论失效

我曾用"Mac 的 `pbpaste` 变成了 iOS 发出的文本"来证明 iPhone → Mac 通了。**那不是证据**——模拟器的剪贴板本来就会同步回 Mac,不需要 Hypo 参与。

反方向的验证仍然成立,因为看的是日志里的信封解码,那只可能来自 Hypo:

```
📦 Decoded envelope: deviceName=derek's MacBook Air (2), origin=cloud
```

### 用正确的证据重验

查 **macOS 应用自己的历史**,里面有:

```
- 'iPhone 17' | "a long entry that the row cannot show in f…"
```

`originDeviceName` 是 iPhone 17,**只有 Hypo 把它当作来自 iPhone 的远程条目接收才会这样记录**;剪贴板同步只会让它成为 Mac 的本地条目。所以 iPhone → Mac 确实通,结论不变,证据换了。

### 两条后果

**一、测试会污染真实机器。** Mac 的历史里那些 `foreign text XXXX`、`something worth sending XXXX` 全是测试字符串,经模拟器剪贴板同步流到 Mac、再被 Hypo 记录。在本机跑这些测试等于往用户的剪贴板历史里灌数据。

**二、"内容出现在对面"永远不能作为同步的证据**,只要两端共用剪贴板。判据必须是接收方**应用**的记录:日志里的信封解码,或历史条目的 `originDeviceName`。

关掉模拟器的 Edit → Automatically Sync Pasteboard 可以消除这个混淆,但那会让"外来剪贴板内容"的测试没法用 `pbcopy` 来准备。目前保持开启,并在判据上绕开它。


## 固定 sleep 做同步,在 CI 上会挂死（2026-09-01）

`Run HypoCore tests on iOS Simulator` 在 CI 上跑满 20 分钟被杀,最后一行停在:

```
◇ Test testDisconnectWhileConnectingCancelsHandshake() started.
🚀 [LanWebSocketTransport] Resuming WebSocket task
```

这个测试**用的是 Stub,根本不碰网络**,URL 只是占位。挂住的是时序:它固定 `sleep 50ms` 之后调用 `disconnect()`,假定那时 `connect()` 已经走到"取消才有意义"的位置。CI 机器慢的时候并没有,于是断开取消不到任何东西,`connectTask.value` 永远不返回。

改成**等待 stub 的 `onResume` 真的被调用**——那正是同一个时刻,但是观测到的而不是猜的——并给测试加 `.timeLimit(.minutes(1))`。

之前加的单步超时在这里兑现了价值:失败发生在 20 分钟而不是烧满整个 job,而且日志明确停在哪个测试上。**挂死本身难免,但它必须说得出自己停在哪里。**


### 改布局会改变可访问性树,断言要按"包含"匹配

把状态行从 `Label` 换成 `HStack` 之后,CI 报:

```
the status row showed none of ["Disconnected", …]:
["Settings", "Connection", "Status", "Status, Disconnected", …]
```

**标签和值被合并成了一个元素**——`"Status, Disconnected"`。查找独立的 `"Disconnected"` 在合并前成立,布局一改就失效,而 app 的行为一点没变。

改成在所有标签里按**包含**匹配。这一类断言(按精确名字取元素)在 SwiftUI 里都很脆:同一段内容会因为外层容器不同而变成一个或多个元素。本期已经被这件事绊过三次——配对行的标识符合并、成功页文案、现在是状态行。
