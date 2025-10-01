# Product Requirements Document: Cross-Platform Clipboard Sync

## Project Overview
- **Project**: Cross-Platform Clipboard Sync
- **Platforms**: Android (HyperOS 3+) and macOS 26+
- **Owner**: TBD
- **Version**: Draft v0.1

## 1. Purpose
Users frequently move between Xiaomi/HyperOS devices and macOS machines but lack a native universal clipboard. This product will enable real-time, bi-directional clipboard synchronization across devices, supporting both LAN (local network) for speed and efficiency and a cloud fallback for mobility. It should also provide clipboard history on macOS, with rich notifications and cross-format support for text, links, images, and small files.

## 2. Goals & Objectives
- Enable dual-sync clipboard between Android/HyperOS and macOS.
- Prioritize LAN-first sync (Wi-Fi / Bonjour / mDNS discovery) with a fallback to cloud relay when no local path is available.
- Support common clipboard data types:
  - Plain text
  - Links/URLs
  - Images (PNG/JPEG under 1 MB)
  - Files (≤ 1 MB)
- Provide native clipboard history on macOS 26, searchable with timestamps.
- Notify macOS users when a new clipboard item arrives from mobile.
- Ensure modern, minimal UI/UX, consistent with macOS and Android design guidelines.

## 3. Non-Goals
- Not designed for very large file transfers (> 1 MB).
- No guarantee of perfect fidelity for proprietary clipboard formats (e.g., styled RTF from Word).

## 4. Key Features

### 4.1 Dual Sync Engine
- Android → macOS: Push clipboard updates in real time.
- macOS → Android: Capture pasteboard changes (NSPasteboard) and push to the Android app.
- De-duplication logic: prevent infinite ping-pong loops.
- Configurable update throttling (for example, no more than one update every 300 ms).

### 4.2 Transport Layer
- **Local network sync**
  - Use mDNS / Bonjour for discovery.
  - TLS over WebSocket for direct LAN connection.
- **Cloud relay (fallback)**
  - Secure WebSocket via backend relay server.
  - End-to-end encryption to ensure privacy.

### 4.3 Clipboard Data Support
- Text/Links/URLs: UTF-8 encoded.
- Images: Compressed to PNG or JPEG.
- Files: Base64-encoded small files (< 1 MB).

### 4.4 macOS Features
- Notification Center integration: Display incoming clipboard updates with previews (for example, text snippet or image thumbnail).
- Clipboard history UI:
  - Menu-bar dropdown.
  - Search/filter by type or date.
  - Up to N (configurable, default 200) entries stored locally.

### 4.5 Android Features
- Foreground service to listen to the clipboard.
- Permissions handling for background clipboard read/write (workarounds for Android restrictions).
- Simple UI: history, settings (LAN/Cloud priority, encryption key management).

### 4.6 Security & Privacy
- End-to-end AES-256 encryption of clipboard data.
- Device pairing via QR code scan (exchange keys over local network).
- Optional auto-expire clipboard items (for example, delete after X hours).

## 5. Technical Requirements

### macOS Client
- Language: Swift/SwiftUI + AppKit (NSPasteboard).
- Background agent + menu-bar app.
- Notifications via the macOS 26 notification framework.

### Android Client
- Language: Kotlin.
- ClipboardManager API.
- Foreground Service to bypass background restrictions.

### Backend (Cloud Relay)
- Lightweight WebSocket server (Node.js, Go, or Rust).
- Stateless design that relays only encrypted payloads.
- Protocol format:

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "type": "text|link|image|file",
  "payload": "base64/string",
  "device": "android|macos"
}
```

## 6. User Stories
1. As a user, I copy a text snippet on my Xiaomi phone, and within 1 s, it appears on my Mac.
2. As a user, I copy an image (≤ 1 MB) on my Mac, and it syncs to my phone’s clipboard.
3. As a user, I want a macOS menu-bar app to view my clipboard history and paste from it.
4. As a user, if I’m away from my LAN, I want the clipboard to still sync via the cloud.
5. As a user, I want notifications on macOS when a new clipboard item arrives from my phone.

## 7. UX / UI Concepts

### macOS
- Menu bar icon with clipboard count.
- History popup with search box and previews.

### Android
- Clean Material You interface.
- Switch between LAN/Cloud, manage keys, view history.

## 8. Risks / Challenges
- Android background clipboard access restrictions (HyperOS may add more).
- Maintaining performance with image/file transfers.
- Latency issues if cloud fallback is the only available path.
- Security: clipboard may contain sensitive data, so encryption must be strong.

## 9. Success Metrics
- Median sync latency < 1 s (LAN).
- Error rate < 0.1%.
- 95% of transfers under 1 MB succeed in < 3 s via cloud.
- User satisfaction rating ≥ 4.5 in beta test.

## 10. Suggestions for Expansion
- Add multi-device sync (Mac ↔ multiple phones).
- Add end-to-end logs and analytics (debug mode).
- Optionally integrate with iCloud Drive or Google Drive for larger files.
- Add cross-device search: search clipboard history across all devices.

## 11. UX / UI Wireframes (Conceptual)

### macOS 26 (Menu Bar App + History)
- **Menu Bar Dropdown**
  - Top section: Latest clipboard item preview.
  - Shows icon by type: 📋 text, 🔗 link, 🖼 image, 📄 file.
  - Hover → “Copy to Clipboard Again.”
  - Middle section: History list (scrollable, approximately 10–15 recent items).
  - Each entry: small icon plus truncated text, filename, or thumbnail.
  - Right-click → options (Copy, Pin, Delete).
  - Bottom section includes a search bar (filter by keyword, type, or date) and a settings gear.
- **Notification Center**
  - Rich preview of new incoming item:
    - Text → show first 100 characters.
    - Link → show domain and favicon.
    - Image → small thumbnail.
    - File → filename and size.

### Android / HyperOS 3 (App + Foreground Service)
- **Home Screen**
  - Header: “Clipboard Sync” with device connection status (LAN / Cloud / Offline).
  - Large card for the last clipboard item (preview plus “Share to Mac” button if sync fails).
  - History section: chronological list with type icons, searchable.
- **Settings Screen**
  - Toggles: Enable LAN sync / Enable Cloud sync.
  - Encryption keys management (pair device via QR code).
  - Data retention settings (history size, auto-delete after N days).
  - Battery optimization whitelist instructions.
- **Foreground Service Notification**
  - Persistent notification: “Clipboard sync active.”
  - Quick action buttons: Pause, Resume, Push last item.

## 12. Suggested Visual Style
- macOS: Light/dark mode adaptive, rounded cards, native SF Symbols icons.
- Android/HyperOS: Material You theming with color-adaptive widgets.
- Consistency: Use the same symbols for content types (text/link/image/file) across both platforms.

## 13. Future Expansion (UI Hooks)
- Multi-device support: device list in settings.
- Drag-and-drop files directly into the menu bar app for instant sharing.
- Contextual actions: for example, links open directly in browser, images preview fullscreen.

