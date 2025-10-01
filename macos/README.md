# Hypo macOS Client

Native macOS application for clipboard synchronization, built with Swift 6 and SwiftUI.

---

## Overview

The macOS client provides:
- Menu bar app for quick access to clipboard history
- Real-time clipboard monitoring via NSPasteboard
- Rich notifications when receiving clipboard from Android
- Local history storage with Core Data
- Full-text search across clipboard history
- Device pairing via QR code generation

---

## Requirements

- **macOS**: 26+ (Sequoia or later)
- **Xcode**: 15+ 
- **Swift**: 6.0+
- **Deployment Target**: macOS 26.0

---

## Architecture

```
HypoApp/
├── App.swift                   # Main app entry, MenuBarExtra
├── Views/
│   ├── MenuBarView.swift       # Main menu bar dropdown UI
│   ├── HistoryListView.swift   # Scrollable history with search
│   ├── SettingsView.swift      # App settings and preferences
│   ├── PairingView.swift       # QR code generation for pairing
│   └── Components/
│       ├── ClipboardItemRow.swift
│       └── ContentPreview.swift
├── Models/
│   ├── ClipboardItem.swift     # Core Data entity
│   ├── SyncMessage.swift       # Protocol message model
│   └── DeviceInfo.swift
├── Services/
│   ├── ClipboardMonitor.swift  # NSPasteboard polling
│   ├── SyncEngine.swift        # Main sync orchestration
│   ├── TransportManager.swift  # LAN/Cloud transport selection
│   ├── CryptoService.swift     # AES-256-GCM encryption
│   └── HistoryManager.swift    # Core Data CRUD operations
├── Network/
│   ├── BonjourBrowser.swift    # mDNS discovery
│   ├── WebSocketClient.swift   # WebSocket implementation
│   └── CloudRelayClient.swift
├── Utilities/
│   ├── KeychainManager.swift   # Secure key storage
│   ├── NotificationManager.swift
│   └── Logger.swift
└── Resources/
    ├── Hypo.xcdatamodeld        # Core Data schema
    ├── Assets.xcassets
    └── Info.plist
```

---

## Getting Started

### 1. Open Project

```bash
cd macos
open Hypo.xcodeproj
```

### 2. Configure Signing

1. Select `Hypo` target in Xcode
2. Go to **Signing & Capabilities**
3. Select your development team
4. Enable the following capabilities:
   - **App Sandbox** (with network access)
   - **Keychain Sharing** (group: `com.hypo.shared`)
   - **User Notifications**

### 3. Build and Run

Press `⌘R` or click the **Run** button in Xcode.

---

## Key Components

### ClipboardMonitor

Polls NSPasteboard every 500ms to detect clipboard changes.

```swift
class ClipboardMonitor: ObservableObject {
    private var changeCount: Int = 0
    private var timer: Timer?
    
    func start() {
        changeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    private func checkForChanges() {
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != changeCount {
            changeCount = currentCount
            handleClipboardChange()
        }
    }
}
```

### SyncEngine

Coordinates clipboard changes, encryption, and transport.

```swift
actor SyncEngine {
    private let monitor: ClipboardMonitor
    private let transport: TransportManager
    private let crypto: CryptoService
    private let history: HistoryManager
    
    private var lastSentHash: String?
    private var lastReceivedHash: String?
    
    func handleClipboardChange(_ item: ClipboardItem) async {
        let hash = item.contentHash
        guard hash != lastSentHash && hash != lastReceivedHash else { return }
        
        let encrypted = try await crypto.encrypt(item)
        try await transport.send(encrypted)
        
        lastSentHash = hash
        await history.save(item)
    }
    
    func handleReceivedClipboard(_ message: SyncMessage) async {
        let decrypted = try await crypto.decrypt(message)
        
        lastReceivedHash = decrypted.contentHash
        await NSPasteboard.general.setClipboardItem(decrypted)
        await history.save(decrypted)
        await NotificationManager.shared.show(for: decrypted)
    }
}
```

### TransportManager

Attempts LAN connection first, falls back to cloud relay.

```swift
actor TransportManager {
    private var lanClient: WebSocketClient?
    private var cloudClient: CloudRelayClient?
    
    func send(_ message: SyncMessage) async throws {
        // Try LAN first with 3-second timeout
        if let lanClient = lanClient, await lanClient.isConnected {
            try await lanClient.send(message)
            return
        }
        
        // Fallback to cloud relay
        if cloudClient == nil {
            cloudClient = CloudRelayClient()
            try await cloudClient?.connect()
        }
        try await cloudClient?.send(message)
    }
}
```

---

## Core Data Schema

```swift
@Model
final class ClipboardItem {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var type: ContentType
    var data: Data
    var previewText: String
    var metadata: String? // JSON
    var deviceId: String
    var isPinned: Bool
    
    enum ContentType: String, Codable {
        case text, link, image, file
    }
}
```

---

## Dependencies

Uses Swift Package Manager (SPM):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"), // WebSocket
]
```

---

## Testing

### Unit Tests

```bash
xcodebuild test -scheme Hypo -destination 'platform=macOS'
```

### Manual Testing Checklist

- [ ] Copy text → verify sync to Android
- [ ] Receive text from Android → verify NSPasteboard update
- [ ] Receive image from Android → verify notification with thumbnail
- [ ] Search clipboard history
- [ ] Delete history item
- [ ] Generate QR code for pairing
- [ ] Toggle LAN/Cloud sync in settings

---

## Build Configurations

### Debug
- Console logging enabled
- Network traffic logging
- Unencrypted local storage for debugging

### Release
- Optimizations enabled
- Logging minimal
- Code signing for distribution
- Notarization for Gatekeeper

---

## Distribution

### Direct Distribution

```bash
# Archive
xcodebuild archive -scheme Hypo -archivePath build/Hypo.xcarchive

# Export
xcodebuild -exportArchive -archivePath build/Hypo.xcarchive \
    -exportPath build/ -exportOptionsPlist ExportOptions.plist

# Create DMG
create-dmg --volname "Hypo" --window-size 600 400 \
    Hypo.dmg build/Hypo.app
```

### Mac App Store (Future)

Requires sandbox adjustments:
- Request entitlement for clipboard access
- Request entitlement for network access
- Remove Bonjour if sandboxed (cloud-only mode)

---

## Performance Targets

- **Memory**: < 50MB idle
- **CPU**: < 1% idle, < 10% active sync
- **Network**: < 100KB/min average
- **Disk**: < 10MB database for 200 items

---

## Known Issues

- NSPasteboard has no change notification API (polling required)
- Sandbox may limit Bonjour discovery (entitlement needed)
- Some apps clear clipboard on quit (expected behavior)

---

## Roadmap

- [ ] Implement clipboard filtering (exclude password managers)
- [ ] Add CloudKit sync for history across user's Macs
- [ ] Support drag-and-drop from history
- [ ] Add keyboard shortcuts (⌘⇧V for history)
- [ ] Implement smart paste suggestions

---

**Status**: In Development  
**Last Updated**: October 1, 2025

