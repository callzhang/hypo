# Hypo User Guide

**Cross-Platform Clipboard Synchronization**  
**Version**: 1.0.5  
**Last Updated**: December 5, 2025

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
- **📲 SMS Sync**: Automatically sync incoming SMS messages to macOS (Android)
- **🔋 Battery Optimized**: 60-80% reduction in battery drain when screen off
- **🎯 MIUI/HyperOS Optimized**: Automatic workarounds for Xiaomi device restrictions

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

### Prerequisites

#### System Requirements

| Platform | Minimum Requirements |
|----------|---------------------|
| **macOS** | macOS 14.0+, 4GB RAM, 50MB storage |
| **Android** | Android 8.0+ (API 26), 2GB RAM, 20MB storage (release APK) |
| **Network** | Wi-Fi connection required for both devices |

**Note**: Android release APK is optimized (~15-20MB). Debug APK is larger (~47MB) for development.

#### Before You Begin

- [ ] Both devices connected to internet
- [ ] Administrative access on macOS for permissions
- [ ] Android device allows installing from unknown sources (if using APK)
- [ ] 15 minutes for complete setup

---

### macOS Installation

#### Option 1: Direct Download (Recommended)

1. **Download Application**
   ```bash
   # Download from releases page
   curl -L https://github.com/callzhang/hypo/releases/latest/download/Hypo-1.0.2.zip -o Hypo-1.0.2.zip
   unzip Hypo-1.0.2.zip
   ```

2. **Remove Quarantine Attribute** (Required for downloaded apps)
   ```bash
   # macOS adds quarantine attribute when downloading from internet
   # This causes "app is damaged" error - remove it:
   xattr -d com.apple.quarantine HypoApp.app
   ```

3. **Install to Applications**
   ```bash
   # Move to Applications folder
   sudo mv HypoApp.app /Applications/
   
   # Make executable (if needed)
   chmod +x /Applications/HypoApp.app/Contents/MacOS/HypoMenuBar
   ```

4. **First Launch & Permissions**
   ```bash
   # Launch from command line first time
   open /Applications/HypoApp.app
   ```
   
   **Grant Required Permissions**:
   - **Accessibility**: System Settings → Privacy & Security → Accessibility → Add Hypo
   - **Network**: Allow when prompted
   - **Notifications**: System Settings → Notifications → Hypo → Allow

5. **Verify Installation**
   - Hypo icon appears in menu bar
   - Click icon → "Settings" → Check version number
   - Status should show "Ready to pair"

#### Option 2: Build from Source

1. **Install Dependencies**
   ```bash
   # Install Xcode and command line tools
   xcode-select --install
   
   # Clone repository
   git clone https://github.com/callzhang/hypo.git
   cd hypo
   ```

2. **Build Application Using Build Script (Recommended)**
   ```bash
   # Build macOS app (debug, default)
   ./scripts/build-macos.sh
   
   # Build release version
   ./scripts/build-macos.sh release
   
   # Clean build (removes build cache)
   ./scripts/build-macos.sh clean
   ```
   
   The script will:
   - Build the app using Swift Package Manager
   - Create `HypoApp.app` bundle (debug) or `HypoApp-release.app` bundle (release)
   - Sign the app for local development

3. **Build Application Using Xcode**
   ```bash
   cd macos
   
   # Open in Xcode
   open HypoApp.xcworkspace
   
   # Or build from command line
   xcodebuild -workspace HypoApp.xcworkspace \
              -scheme HypoApp \
              -configuration Release \
              -derivedDataPath build/
   ```

4. **Install Built App**
   ```bash
   # From build script output
   # Debug app is built at: macos/HypoApp.app
   # Release app is built at: macos/HypoApp-release.app
   
   # Or from Xcode build
   cp -r build/Build/Products/Release/HypoApp.app /Applications/
   ```

#### Auto-Start Setup (Optional)

```bash
# Create launch agent for auto-start
cat > ~/Library/LaunchAgents/com.hypo.agent.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hypo.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/HypoApp.app/Contents/MacOS/HypoMenuBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# Load the launch agent
launchctl load ~/Library/LaunchAgents/com.hypo.agent.plist
```

---

### Android Installation

#### Option 1: APK Installation (Current Method)

1. **Download APK**
   ```bash
   # Download latest APK
   curl -L https://github.com/callzhang/hypo/releases/latest/download/Hypo.1.0.2.apk \
        -o Hypo.1.0.2.apk
   ```

2. **Enable Unknown Sources**
   - Android 8+: Settings → Apps & notifications → Special app access → Install unknown apps
   - Select your browser/file manager → Allow from this source

3. **Install Application**
   ```bash
   # Via ADB (if enabled)
   adb install Hypo.1.0.2.apk
   
   # Or manually: Open file manager → Navigate to APK → Tap to install
   ```

4. **Grant Permissions**
   - **Required Immediately**: Storage, Network
   - **Required for Sync**: Accessibility (for clipboard monitoring)
   - **Optional but Recommended**: SMS (for SMS auto-sync feature)
   - **Android 13+**: Notification permission (for foreground service)
   - **Critical**: Disable battery optimization for reliable sync

5. **Battery Optimization (Critical)**
   ```
   Settings → Battery → Battery Optimization → Hypo → Don't optimize
   ```
   
   **Manufacturer-Specific Settings**:
   
   **Samsung**:
   ```
   Settings → Device care → Battery → App power management
   → Apps that won't be put to sleep → Add Hypo
   ```
   
   **Xiaomi (MIUI/HyperOS)**:
   ```
   Settings → Apps → Manage apps → Hypo → Battery saver → No restrictions
   Settings → Apps → Manage apps → Hypo → Autostart → Enable
   ```
   
   **Note**: Hypo automatically detects MIUI/HyperOS devices and applies workarounds for multicast throttling. The app will show device-specific instructions in Settings when detected.
   
   **OnePlus/OxygenOS**:
   ```
   Settings → Battery → Battery optimization → Hypo → Don't optimize
   Settings → Apps → Hypo → Advanced → Battery → Background activity → Allow
   ```
   
   **Huawei**:
   ```
   Settings → Apps → Hypo → Battery → App launch → Manage manually
   → Enable all three toggles (Auto-launch, Secondary launch, Run in background)
   ```

#### Option 2: Google Play Store (Coming Soon)

```
Google Play Store → Search "Hypo Clipboard" → Install
```

#### Option 3: Build from Source

1. **Setup Development Environment**
   ```bash
   # Install OpenJDK 17
   brew install openjdk@17
   
   # Setup Android SDK (if not using Android Studio)
   ./scripts/setup-android-sdk.sh
   
   # Clone repository
   git clone https://github.com/callzhang/hypo.git
   cd hypo
   ```

2. **Build APK Using Build Script (Recommended)**
   ```bash
   # Build debug APK (default, for development/testing)
   ./scripts/build-android.sh
   
   # Build release APK (optimized, ~15-20MB)
   ./scripts/build-android.sh release
   
   # Build both debug and release APKs
   ./scripts/build-android.sh both
   
   # Clean build (removes build cache)
   ./scripts/build-android.sh clean
   ```
   
   **Build Output**:
   - Debug APK: `android/app/build/outputs/apk/debug/app-debug.apk` (~47MB)
   - Release APK: `android/app/build/outputs/apk/release/app-release.apk` (~15-20MB)

3. **Build APK Using Gradle Directly**
   ```bash
   cd android
   
   # Set Android SDK path (if not set)
   export ANDROID_SDK_ROOT=/path/to/android-sdk
   export JAVA_HOME=/path/to/java-17
   
   # Build debug APK
   ./gradlew assembleDebug
   
   # Build release APK (optimized with R8/ProGuard)
   ./gradlew assembleRelease
   ```

4. **Install Built APK**
   ```bash
   # Install debug APK via ADB (auto-installs if device connected, default)
   ./scripts/build-android.sh
   
   # Or manually install
   adb install android/app/build/outputs/apk/debug/app-debug.apk
   adb install android/app/build/outputs/apk/release/app-release.apk
   ```

**Build Optimizations**:
- Release builds are optimized with R8/ProGuard minification
- Only arm64-v8a ABI included in release (saves ~15MB)
- Unused dependencies removed (ML Kit, Camera libraries)
- Resource shrinking enabled

---

### Device Pairing

#### Method 1: LAN Auto-Discovery Pairing (Same Network)

**Prerequisites**: Both devices on same Wi-Fi network

1. **Start Pairing (macOS)**
   ```
   Menu Bar Icon → Pair Device
   (macOS will automatically advertise itself on the network)
   ```

2. **Pair Device (Android)**
   ```
   Open Hypo → Pair Device → Select "LAN" tab
   → Wait for macOS device to appear
   → Tap on the device to pair
   ```

3. **Verify Connection**
   - Both apps show "Connected" status
   - Test by copying text on either device

#### Method 2: Remote Pairing (Different Networks)

**Prerequisites**: Both devices have internet connection

1. **Generate Pairing Code (macOS)**
   ```
   Menu Bar Icon → Pair Device → Remote Pairing
   → Note 6-digit code (valid 60 seconds)
   ```

2. **Enter Code (Android)**
   ```
   Open Hypo → Pair Device → Enter Code
   → Type 6-digit code → Pair
   ```

3. **Verify Connection**
   - Connection status shows "Cloud" mode
   - Test clipboard sync between devices

---

### Verification & Testing

#### Connection Test

1. **Basic Sync Test**
   ```
   macOS: Copy some text (⌘C)
   Android: Check if text appears in clipboard
   Android: Copy different text
   macOS: Check if text syncs back
   ```

2. **History Test**
   ```
   macOS: Menu Bar → View History → Should see recent items
   Android: Open app → History tab → Should see same items
   ```

3. **Performance Test**
   ```
   Copy text → Time how long sync takes
   Target: <500ms on LAN, <3s on cloud
   ```

#### Troubleshooting Verification

**macOS Checks**:
```bash
# Check if app is running
ps aux | grep Hypo

# Check accessibility permission
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT * FROM access WHERE service='kTCCServiceAccessibility';"

# Check network connectivity
nc -v your-android-ip 1234  # Should show connection attempts
```

**Android Checks**:
```bash
# Check if service is running
adb shell dumpsys activity services | grep Hypo

# Check battery optimization status
adb shell dumpsys deviceidle whitelist | grep hypo

# Check permissions
adb shell pm list permissions -d | grep hypo
```

---

### Configuration

#### macOS Configuration

**Settings File Location**: `~/Library/Application Support/Hypo/`

**Command Line Configuration**:
```bash
# Set history size
defaults write com.hypo.clipboard historySize -int 500

# Enable debug logging
defaults write com.hypo.clipboard debugLogging -bool true

# Set sync timeout
defaults write com.hypo.clipboard syncTimeout -int 5000
```

#### Android Configuration

**Settings Location**: App → Settings menu

**Key Settings**:
- **Sync Frequency**: Auto/Manual/Scheduled
- **History Retention**: 50-1000 items
- **Battery Optimization**: Enabled/Disabled
- **Network Preference**: LAN Only/Cloud Fallback/Cloud Only

**Advanced Configuration** (via ADB):
```bash
# Enable debug mode
adb shell am start -n com.hypo.clipboard/.MainActivity \
  --es "debug_mode" "true"

# Set custom sync interval
adb shell setprop persist.hypo.sync_interval 1000
```

---

### Updates

#### macOS Updates

**Manual Updates**:
1. Download new version from [GitHub Releases](https://github.com/callzhang/hypo/releases)
2. Quit current app: `Menu Bar → Quit`
3. Remove quarantine: `xattr -d com.apple.quarantine HypoApp.app`
4. Replace in Applications folder
5. Restart app

#### Android Updates

**APK Updates**:
1. Download new APK from [GitHub Releases](https://github.com/callzhang/hypo/releases)
2. Install over existing app (data preserved)
3. Grant any new permissions

---

### Uninstallation

#### macOS Removal

```bash
# Stop the app
killall HypoMenuBar

# Remove launch agent (if installed)
launchctl unload ~/Library/LaunchAgents/com.hypo.agent.plist 2>/dev/null || true
rm ~/Library/LaunchAgents/com.hypo.agent.plist 2>/dev/null || true

# Remove application
rm -rf /Applications/HypoApp.app
rm -rf /Applications/HypoApp-release.app

# Remove preferences and data
rm -rf ~/Library/Preferences/com.hypo.clipboard.*
rm -rf ~/Library/Application\ Support/Hypo
rm -rf ~/Library/Logs/Hypo
```

#### Android Removal

```bash
# Via ADB (debug build)
adb uninstall com.hypo.clipboard.debug

# Via ADB (release build)
adb uninstall com.hypo.clipboard

# Or manually: Settings → Apps → Hypo → Uninstall
```

**Note**: 
- Debug builds use package name: `com.hypo.clipboard.debug`
- Release builds use package name: `com.hypo.clipboard`
- All clipboard history and pairing keys will be permanently deleted

---

### Build Information

#### Android APK Sizes

| Build Type | Size | Use Case |
|------------|------|----------|
| **Debug APK** | ~47MB | Development, testing, emulator |
| **Release APK** | ~15-20MB | Production distribution |
| **Release AAB** | ~12-15MB | Google Play Store (when available) |

#### Build Optimizations

The release APK includes the following optimizations:
- **Code minification**: R8/ProGuard removes unused code (~20-25MB savings)
- **Resource shrinking**: Unused resources removed
- **ABI filtering**: Only arm64-v8a included (~15MB savings)
- **Dependency optimization**: Removed unused libraries (ML Kit, Camera, etc.)

#### Building App Bundle (AAB) for Play Store

```bash
cd android
./gradlew bundleRelease

# Output: app/build/outputs/bundle/release/app-release.aab
```

The App Bundle format allows Google Play to generate optimized APKs per device, resulting in smaller downloads for end users.

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
- **Text**: Plain text (unlimited size, but sync limited to 10MB)
- **Links**: URLs automatically detected and validated
- **Images**: PNG, JPEG, GIF, WebP up to 10MB (sync limit)
- **Files**: Files up to 10MB (sync limit)

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
- **Tap Item**: Copy to clipboard, item moves to top of history, and view automatically scrolls to show it
- **Long Press**: Options menu (pin, delete, share)
- **Swipe Left**: Delete item
- **Swipe Right**: Pin/unpin item
- **Pull to Refresh**: Sync with other devices
- **Text Selection Context Menu**: Select text in any app → "Copy to Hypo" appears first in menu → Automatically copies and syncs to other devices

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
- **SMS Auto-Sync**: Enable/disable automatic SMS copying and syncing
- **Permissions**: View and manage app permissions (SMS, notifications)
- **MIUI/HyperOS**: Automatic optimization settings (if detected)
- **Text Selection**: "Copy to Hypo" context menu item (appears first in text selection menu)

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

**For MIUI/HyperOS Users**:
- App automatically applies workarounds for multicast throttling
- Ensure "Autostart" is enabled: Settings → Apps → Manage apps → Hypo → Autostart
- Settings screen shows device-specific instructions when MIUI/HyperOS is detected

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

**Q: Can Hypo sync SMS messages?**  
A: Yes! On Android, Hypo can automatically copy incoming SMS messages to the clipboard and sync them to macOS. Enable SMS permission in Settings to use this feature. Note: Android 10+ may have restrictions on SMS access.

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
A: 
- **Sync Limit**: 10MB per item (images and files)
- **Copy Limit**: 50MB per item (prevents excessive disk usage)
- Items larger than 10MB cannot be synced between devices
- Items larger than 50MB cannot be copied to clipboard (but can be synced if under 10MB)
- Temporary files are automatically cleaned up after 30 seconds or when clipboard changes

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

**Version 1.0.2** (Current - Build & Release Improvements)
- macOS app signing for free distribution (ad-hoc signing)
- Automatic release notes generation
- Android build optimizations (faster CI/CD builds)
- Improved backend deployment workflow

**Version 1.0.1** (Production Release)
- Production-ready release
- Full clipboard sync functionality
- LAN auto-discovery and remote pairing
- End-to-end encryption (AES-256-GCM)
- Clipboard history and search
- SMS auto-sync (Android → macOS)
- MIUI/HyperOS optimization and workarounds
- Battery optimization (60-80% reduction when screen off)
- Automated build and release pipeline
- Comprehensive documentation

**Version 1.0.0** (December 2025)
- Initial production release
- Device-agnostic pairing system
- Production backend deployment
- All core features implemented

**Upcoming Features**:
- Multi-device support (>2 devices)
- iOS support
- Large file sync via cloud storage
- Advanced clipboard filtering
- OCR for image text extraction

---

**Last Updated**: December 5, 2025  
**Version**: 1.0.5  
**For Technical Support**: support@hypo.app