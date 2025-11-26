# Hypo User Guide

**Cross-Platform Clipboard Synchronization**  
**Version**: 0.2.3 Beta  
**Last Updated**: November 26, 2025

---

## 📖 Table of Contents

1. [What is Hypo?](#what-is-hypo)
2. [System Requirements](#system-requirements)
3. [Installation](#installation)
4. [Getting Started](#getting-started)
5. [Features](#features)
6. [Usage](#usage)
7. [Troubleshooting](#troubleshooting)
8. [FAQ](#faq)
9. [Support](#support)

---

## 🎯 What is Hypo?

Hypo is a secure, real-time clipboard synchronization app that seamlessly connects your macOS and Android devices. Copy something on one device and instantly paste it on another – no cloud storage required for most operations.

### Key Features
- **🔒 Secure**: End-to-end encryption with AES-256-GCM
- **⚡ Fast**: Local network sync typically under 500ms
- **📱 Cross-Platform**: Works between macOS and Android
- **🏠 Local First**: Prefers direct device connection over cloud
- **📝 Rich Content**: Supports text, links, images, and small files
- **📂 History**: Keep track of your last 200 clipboard items
- **🔍 Search**: Find any copied content instantly

---

## ⚙️ System Requirements

### macOS
- **OS Version**: macOS 14.0 (Sonoma) or later
- **Memory**: 4GB RAM minimum
- **Storage**: 50MB available space
- **Network**: Wi-Fi connection (for LAN sync and cloud fallback)
- **Current Status**: ✅ Production-ready, fully functional

### Android
- **OS Version**: Android 8.0 (API 26) or later  
  *(Tested on Android 8-14, HyperOS 3+)*
- **Memory**: 2GB RAM minimum
- **Storage**: 100MB available space
- **Permissions**: Clipboard access, network access, notification access
- **Network**: Wi-Fi connection (for LAN sync and cloud fallback)
- **Current Status**: ✅ Production-ready, fully functional
- **Battery**: Optimized for minimal drain (60-80% reduction when screen off)

---

## 📦 Installation

### macOS Installation

1. **Download the App**
   - Download `Hypo.app` from the releases page
   - Or build from source (see Developer Guide)

2. **Install the Application**
   ```bash
   # Move to Applications folder
   mv Hypo.app /Applications/
   
   # Grant necessary permissions when prompted
   ```

3. **First Launch**
   - Launch Hypo from Applications or Spotlight
   - Grant clipboard access permission when prompted
   - The app will appear in your menu bar (clipboard icon)

4. **Launch Agent Setup (Optional)**
   ```bash
   # For automatic startup (recommended)
   cp ~/Library/LaunchAgents/com.hypo.agent.plist
   launchctl load ~/Library/LaunchAgents/com.hypo.agent.plist
   ```

### Android Installation

1. **Download the APK**
   - Download `hypo-clipboard.apk` from the releases page
   - Or install from Google Play Store (coming soon)

2. **Install the App**
   ```bash
   # Enable "Install from Unknown Sources" if installing APK
   adb install hypo-clipboard.apk
   # Or install manually through file manager
   ```

3. **Grant Permissions**
   - **Clipboard Access**: Required for monitoring clipboard changes
   - **Network Access**: Required for device sync
   - **Notification Access**: For sync status and new content alerts
   - **Battery Optimization**: Disable for best performance

4. **Start the Service**
   - Open the app and tap "Start Sync"
   - The foreground service will begin running
   - You'll see a persistent notification

---

## 🚀 Getting Started

### First Time Setup

1. **Start Both Apps**
   - Launch Hypo on macOS (menu bar icon)
   - Launch Hypo on Android and start sync service

2. **Device Pairing** (Choose One Method)

   **Option A: LAN Auto-Discovery (Recommended for same network)**
   1. On macOS: Ensure Hypo is running (menu bar icon visible)
   2. On Android: Tap "Pair Device" → Select "LAN" tab
   3. Wait for your macOS device to appear in the list
   4. Tap on the device to pair
   5. Pairing completes automatically

   **Option B: Code Pairing (For different networks or when LAN discovery fails)**
   1. On macOS: Click menu bar → "Pair Device"
   2. Note the 6-digit pairing code displayed
   3. On Android: Tap "Pair Device" → Select "Code" tab
   4. Enter the 6-digit code
   5. Pairing completes via cloud relay

3. **Test the Connection**
   - Copy some text on either device
   - It should appear on the other device within seconds
   - Check connection status in both apps

### Basic Operation

**macOS**:
- Menu bar icon shows connection status
- Click icon to see clipboard history
- Search through history with ⌘F
- Drag items from history to paste elsewhere

**Android**:
- Notification shows sync status
- Open app to view clipboard history
- Swipe to refresh history
- Tap items to copy them back to clipboard

---

## ✨ Features

### Clipboard Synchronization

**Supported Content Types**:
- **Text**: Plain text up to 100KB
- **Links**: URLs automatically detected and validated
- **Images**: PNG/JPEG up to 1MB (auto-compressed)
- **Files**: Small files up to 1MB

**Sync Behavior**:
- Automatic sync within 300ms of clipboard change
- De-duplication prevents sync loops
- Throttling prevents spam (max 1 update per 300ms)

### Connection Methods

**Local Network (Preferred)**:
- Direct device-to-device connection via Wi-Fi
- Fastest sync (typically <500ms)
- No internet required once paired
- Uses mDNS/Bonjour for discovery

**Cloud Relay (Fallback)**:
- Secure relay server for when devices aren't on same network
- End-to-end encrypted (relay cannot read content)
- Slightly slower (typically <3s)
- Automatic fallback when LAN unavailable

### Security & Privacy

**Encryption**:
- AES-256-GCM encryption for all clipboard data
- Unique encryption key per device pair
- Keys rotated every 30 days automatically
- No plaintext data stored on relay servers

**Privacy**:
- No cloud storage of clipboard content
- Relay servers only route encrypted data
- Local storage encrypted on device
- No telemetry unless opted in

### History & Search

**History Management**:
- Stores last 200 clipboard items by default
- Configurable retention (50-1000 items)
- Smart cleanup of old items
- Pin important items to prevent deletion

**Search Features**:
- Real-time search as you type
- Search across all content types
- Search by device source
- Search by date range

---

## 📱 Usage

### macOS Usage

**Menu Bar Controls**:
- **Left Click**: Open clipboard history
- **Right Click**: Access settings and pairing
- **⌘+Space**: Quick search (when history open)
- **Escape**: Close history window

**History Window**:
- **Search Bar**: Type to filter items
- **Content Preview**: See full text/image preview
- **Device Badge**: Shows which device item came from
- **Drag & Drop**: Drag items to other apps to paste
- **Double Click**: Copy item back to clipboard

**Keyboard Shortcuts**:
- `⌘F`: Focus search bar
- `⌘R`: Refresh history
- `⌘,`: Open settings
- `⌘Q`: Quit application
- `↑/↓`: Navigate history items
- `Enter`: Copy selected item

### Android Usage

**Main Screen**:
- **History List**: Scrollable list of clipboard items
- **Search**: Tap search icon to find items
- **Sync Status**: Connection indicator at top
- **Menu**: Access settings and pairing options

**Clipboard Actions**:
- **Tap Item**: Copy to clipboard
- **Long Press**: Options menu (pin, delete, share)
- **Swipe Left**: Delete item
- **Swipe Right**: Pin/unpin item
- **Pull to Refresh**: Sync with other devices

**Notification Actions**:
- **Pause Sync**: Temporarily stop clipboard monitoring
- **Resume Sync**: Restart clipboard monitoring
- **Open History**: Quick access to app
- **Connection Status**: Shows LAN/cloud status

### Settings Configuration

**macOS Settings**:
- **General**: History size, auto-start, notifications
- **Sync**: LAN/cloud preferences, sync frequency
- **Privacy**: Clear history, disable sync temporarily
- **Devices**: Manage paired devices, view encryption keys
- **Advanced**: Debug options, performance tuning

**Android Settings**:
- **Sync Options**: Enable/disable LAN and cloud sync
- **History**: Retention period, automatic cleanup
- **Notifications**: Customize notification behavior
- **Battery**: Optimize for battery vs. performance
- **Privacy**: Data retention, encryption status

---

## 🔧 Troubleshooting

### Common Issues

#### "Devices Not Connecting"

**Symptoms**: Devices paired but sync not working  
**Solutions**:
1. Check both devices on same Wi-Fi network
2. Restart both apps
3. Check firewall settings allow Hypo
4. Try re-pairing devices
5. Check cloud fallback is working

#### "Slow Sync Performance"

**Symptoms**: Clipboard takes >5 seconds to sync  
**Solutions**:
1. Check Wi-Fi signal strength
2. Restart router/Wi-Fi connection
3. Check for network interference
4. Close other network-intensive apps
5. Clear clipboard history (Settings → Clear History)

#### "Android App Killed by System"

**Symptoms**: Sync stops working after phone sleep  
**Solutions**:
1. Disable battery optimization for Hypo
2. Add Hypo to "Protected Apps" (manufacturer specific)
3. Ensure "Auto-start" is enabled
4. Check notification permission granted
5. Restart the sync service

#### "macOS Clipboard Access Denied"

**Symptoms**: macOS cannot read/write clipboard  
**Solutions**:
1. System Settings → Privacy & Security → Accessibility
2. Add Hypo to accessibility apps
3. Restart Hypo after granting permission
4. Check System Integrity Protection not blocking
5. Try running from Applications folder

### Error Messages

#### "Pairing Failed - Code Expired"
- **Cause**: Pairing code older than 60 seconds
- **Solution**: Generate new pairing code and try again

#### "Connection Timeout"
- **Cause**: Network connectivity issue
- **Solution**: Check internet connection and try cloud sync

#### "Encryption Key Mismatch"
- **Cause**: Devices have different encryption keys
- **Solution**: Re-pair devices to generate new shared keys

#### "Storage Full"
- **Cause**: Clipboard history storage limit reached
- **Solution**: Clear old history items or increase storage limit

### Performance Optimization

#### For Better LAN Performance:
- Use 5GHz Wi-Fi when possible
- Keep devices close to router
- Minimize network traffic during sync
- Use ethernet connection for router

#### For Better Battery Life (Android):
- Reduce history retention period
- Disable sync during battery saver mode
- Use "Adaptive" sync frequency
- Close app when not needed

#### For Better Memory Usage:
- Clear history regularly
- Reduce image quality setting
- Limit file sync to smaller sizes
- Restart apps periodically

---

## ❓ FAQ

### General Questions

**Q: Is my clipboard data secure?**  
A: Yes. All data is encrypted end-to-end with AES-256-GCM. Even our relay servers cannot read your clipboard content.

**Q: Does Hypo work without internet?**  
A: Yes, if both devices are on the same Wi-Fi network, they can sync directly without internet.

**Q: How much battery does Hypo use on Android?**  
A: Typically less than 2% per day with optimized settings. The foreground service is designed to be battery-efficient.

**Q: Can I sync between more than 2 devices?**  
A: Currently, Hypo supports pairing between 2 devices. Multi-device support is planned for a future release.

**Q: What happens if I copy a password?**  
A: Passwords are encrypted like any other content. However, we recommend using a dedicated password manager for sensitive credentials.

### Privacy & Security

**Q: Where is my data stored?**  
A: Clipboard history is stored locally on each device in encrypted form. Cloud relay servers never store your content.

**Q: Can your company read my clipboard?**  
A: No. We use end-to-end encryption, so even we cannot decrypt your clipboard content.

**Q: How often are encryption keys rotated?**  
A: Encryption keys are automatically rotated every 30 days with a 7-day grace period for smooth transition.

**Q: What data do you collect?**  
A: By default, we collect no usage data. Optional telemetry can be enabled in settings for performance improvement.

### Technical Questions

**Q: Which ports does Hypo use?**  
A: Hypo uses dynamic ports for LAN discovery (mDNS) and a randomly assigned port for device-to-device communication.

**Q: Can I use Hypo on cellular networks?**  
A: Yes, using cloud relay. However, LAN sync requires both devices on the same Wi-Fi network.

**Q: How large files can I sync?**  
A: Currently limited to 1MB per item. Larger file support via cloud storage is planned for future versions.

**Q: Does Hypo work with VPNs?**  
A: LAN sync may not work with VPN. Cloud relay sync should work normally with most VPN configurations.

---

## 🆘 Support

### Getting Help

**Documentation**:
- User Guide: This document
- [Developer Guide](DEVELOPER_GUIDE.md): For technical users
- [Architecture Overview](architecture.mermaid): System design
- [API Documentation](api.md): For integrators

**Community Support**:
- GitHub Issues: Report bugs and request features
- Discussions: Community questions and tips
- Wiki: Community-maintained guides and tips

**Direct Support**:
- Email: support@hypo.app
- Response time: Within 2 business days
- Include log files when reporting issues

### Reporting Bugs

**Before Reporting**:
1. Check troubleshooting section above
2. Search existing GitHub issues
3. Try reproducing on clean install
4. Gather system information

**Bug Report Template**:
```
**Device Information:**
- macOS version: 
- Android version: 
- Hypo version: 
- Network type: 

**Bug Description:**
- What you expected to happen:
- What actually happened:
- Steps to reproduce:
- Frequency: Always/Sometimes/Rare

**Logs:**
- Attach log files from both devices
- Include screenshot if UI-related
```

**Log File Locations**:
- macOS: `~/Library/Logs/Hypo/`
- Android: Use "Export Logs" in Settings menu

### Feature Requests

We welcome feature requests! Please check our roadmap first, then create a GitHub issue with:
- Clear description of the feature
- Use case and benefits
- Any technical considerations
- Willingness to contribute/test

---

## 📝 Changelog

**Version 0.1.0 Beta** (Current)
- Initial beta release
- Basic clipboard sync functionality
- QR code and remote pairing
- End-to-end encryption
- History and search features
- macOS and Android support

**Upcoming Features**:
- Multi-device support (>2 devices)
- iOS support
- Large file sync via cloud storage
- Advanced clipboard filtering
- OCR for image text extraction

---

**Last Updated**: October 11, 2025  
**Version**: 0.1.0 Beta  
**For Technical Support**: support@hypo.app