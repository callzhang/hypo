# Hypo Installation Guide

**Quick setup guide for macOS and Android**  
**Version**: 0.2.3 Beta  
**Last Updated**: November 26, 2025

---

## 📋 Prerequisites

### System Requirements

| Platform | Minimum Requirements |
|----------|---------------------|
| **macOS** | macOS 14.0+, 4GB RAM, 50MB storage |
| **Android** | Android 8.0+ (API 26), 2GB RAM, 100MB storage |
| **Network** | Wi-Fi connection required for both devices |

### Before You Begin

- [ ] Both devices connected to internet
- [ ] Administrative access on macOS for permissions
- [ ] Android device allows installing from unknown sources (if using APK)
- [ ] 15 minutes for complete setup

---

## 🍎 macOS Installation

### Option 1: Direct Download (Recommended)

1. **Download Application**
   ```bash
   # Download from releases page
   curl -L https://github.com/hypo/releases/latest/download/Hypo.app.zip -o Hypo.app.zip
   unzip Hypo.app.zip
   ```

2. **Install to Applications**
   ```bash
   # Move to Applications folder
   sudo mv Hypo.app /Applications/
   
   # Make executable
   chmod +x /Applications/Hypo.app/Contents/MacOS/Hypo
   ```

3. **First Launch & Permissions**
   ```bash
   # Launch from command line first time
   open /Applications/Hypo.app
   ```
   
   **Grant Required Permissions**:
   - **Accessibility**: System Settings → Privacy & Security → Accessibility → Add Hypo
   - **Network**: Allow when prompted
   - **Notifications**: System Settings → Notifications → Hypo → Allow

4. **Verify Installation**
   - Hypo icon appears in menu bar
   - Click icon → "Settings" → Check version number
   - Status should show "Ready to pair"

### Option 2: Build from Source

1. **Install Dependencies**
   ```bash
   # Install Xcode and command line tools
   xcode-select --install
   
   # Clone repository
   git clone https://github.com/hypo-app/hypo.git
   cd hypo/macos
   ```

2. **Build Application**
   ```bash
   # Open in Xcode
   open HypoApp.xcworkspace
   
   # Or build from command line
   xcodebuild -workspace HypoApp.xcworkspace \
              -scheme HypoApp \
              -configuration Release \
              -derivedDataPath build/
   ```

3. **Install Built App**
   ```bash
   cp -r build/Build/Products/Release/Hypo.app /Applications/
   ```

### Auto-Start Setup (Optional)

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
        <string>/Applications/Hypo.app/Contents/MacOS/Hypo</string>
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

## 🤖 Android Installation

### Option 1: APK Installation (Current Method)

1. **Download APK**
   ```bash
   # Download latest APK
   curl -L https://github.com/hypo/releases/latest/download/hypo-clipboard.apk \
        -o hypo-clipboard.apk
   ```

2. **Enable Unknown Sources**
   - Android 8+: Settings → Apps & notifications → Special app access → Install unknown apps
   - Select your browser/file manager → Allow from this source

3. **Install Application**
   ```bash
   # Via ADB (if enabled)
   adb install hypo-clipboard.apk
   
   # Or manually: Open file manager → Navigate to APK → Tap to install
   ```

4. **Grant Permissions**
   - **Required Immediately**: Storage, Network
   - **Required for Sync**: Accessibility (for clipboard monitoring)
   - **Recommended**: Disable battery optimization

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
   
   **Xiaomi (MIUI)**:
   ```
   Settings → Apps → Manage apps → Hypo → Battery saver → No restrictions
   Security → Permissions → Autostart → Enable Hypo
   ```
   
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

### Option 2: Google Play Store (Coming Soon)

```
Google Play Store → Search "Hypo Clipboard" → Install
```

### Option 3: Build from Source

1. **Setup Development Environment**
   ```bash
   # Install Android Studio
   # Download Android SDK
   
   # Clone repository
   git clone https://github.com/hypo-app/hypo.git
   cd hypo/android
   ```

2. **Build APK**
   ```bash
   # Set Android SDK path
   export ANDROID_SDK_ROOT=/path/to/android-sdk
   
   # Build debug APK
   ./gradlew assembleDebug
   
   # Build release APK (requires signing)
   ./gradlew assembleRelease
   ```

3. **Install Built APK**
   ```bash
   # Install via ADB
   adb install app/build/outputs/apk/debug/app-debug.apk
   ```

---

## 🔄 Device Pairing

### Method 1: LAN Auto-Discovery Pairing (Same Network)

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

### Method 2: Remote Pairing (Different Networks)

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

## ✅ Verification & Testing

### Connection Test

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

### Troubleshooting Verification

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

## 🔧 Configuration

### macOS Configuration

**Settings File Location**: `~/Library/Preferences/com.hypo.plist`

**Key Settings**:
```xml
<!-- Example configuration -->
<key>historySize</key>
<integer>200</integer>
<key>syncMode</key>
<string>auto</string>
<key>encryptionEnabled</key>
<true/>
```

**Command Line Configuration**:
```bash
# Set history size
defaults write com.hypo historySize -int 500

# Enable debug logging
defaults write com.hypo debugLogging -bool true

# Set sync timeout
defaults write com.hypo syncTimeout -int 5000
```

### Android Configuration

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

## 🔄 Updates

### macOS Updates

**Automatic Updates** (if Sparkle framework enabled):
```
Menu Bar → About → Check for Updates
```

**Manual Updates**:
1. Download new version
2. Quit current app: `Menu Bar → Quit`
3. Replace in Applications folder
4. Restart app

### Android Updates

**APK Updates**:
1. Download new APK
2. Install over existing app (data preserved)
3. Grant any new permissions

**Play Store Updates** (when available):
```
Play Store → My apps & games → Hypo → Update
```

---

## 🗑️ Uninstallation

### macOS Removal

```bash
# Stop the app
killall Hypo

# Remove launch agent
launchctl unload ~/Library/LaunchAgents/com.hypo.agent.plist
rm ~/Library/LaunchAgents/com.hypo.agent.plist

# Remove application
rm -rf /Applications/Hypo.app

# Remove preferences and data
rm -rf ~/Library/Preferences/com.hypo.*
rm -rf ~/Library/Application\ Support/Hypo
rm -rf ~/Library/Logs/Hypo

# Remove keychain items (optional)
security delete-generic-password -s "Hypo" -a "$(whoami)"
```

### Android Removal

```bash
# Via ADB
adb uninstall com.hypo.clipboard

# Or manually: Settings → Apps → Hypo → Uninstall
```

**Note**: All clipboard history and pairing keys will be permanently deleted.

---

## 📞 Support

### Installation Issues

**Common Problems**:
- **Permission denied**: Run with `sudo` or check file ownership
- **App won't start**: Check system requirements and permissions
- **Network issues**: Verify firewall settings and network connectivity

**Log Files**:
- macOS: `~/Library/Logs/Hypo/installation.log`
- Android: Settings → Export Installation Logs

**Get Help**:
- GitHub Issues: https://github.com/hypo-app/hypo/issues
- Email Support: install-help@hypo.app
- Community Forum: https://community.hypo.app

---

**Installation Guide Version**: 1.0  
**Compatible with Hypo**: 0.1.0 Beta  
**Last Updated**: October 11, 2025