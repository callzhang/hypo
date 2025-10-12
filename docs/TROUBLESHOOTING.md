# Hypo Troubleshooting Guide

**Comprehensive troubleshooting for Hypo clipboard sync**  
**Version**: 0.1.0 Beta  
**Last Updated**: October 11, 2025

---

## 🚨 Quick Fixes (Try These First)

### The "Have You Tried Turning It Off and On Again?" Checklist

1. **Restart Both Apps**
   - macOS: Menu bar → Quit → Reopen from Applications
   - Android: Force stop app → Reopen and start sync

2. **Check Network Connection**
   - Both devices connected to Wi-Fi
   - Internet connectivity working
   - Same network for LAN sync

3. **Verify Pairing Status**
   - Both apps show "Connected" or "Paired" status
   - Try re-pairing if showing "Disconnected"

4. **Test Basic Functionality**
   - Copy simple text on one device
   - Check if it appears on the other within 10 seconds

**If these don't work, continue to specific troubleshooting sections below.**

---

## 🔗 Connection Issues

### Problem: "Devices Won't Connect"

**Symptoms**: Apps show "Disconnected" or "Pairing Failed"

**Diagnostic Steps**:

1. **Check Network Configuration**
   ```bash
   # macOS: Check network interface
   ifconfig | grep "inet "
   
   # Android: Settings → Wi-Fi → Advanced → IP address
   ```
   
   Both devices should be on same subnet (e.g., 192.168.1.x)

2. **Test Network Connectivity**
   ```bash
   # From macOS, ping Android device
   ping <android-ip-address>
   
   # Should show successful pings
   ```

3. **Check Firewall Settings**
   
   **macOS Firewall**:
   ```
   System Settings → Network → Firewall → Options
   → Add Hypo to allowed apps
   ```
   
   **Router/Network Firewall**:
   - Ensure mDNS/Bonjour traffic allowed
   - Port range 1024-65535 open for local communication

**Solutions**:

**Level 1: Basic Fixes**
- Restart both devices' Wi-Fi
- Move devices closer to router
- Switch to 5GHz Wi-Fi if available

**Level 2: Network Fixes**
- Reset network settings on Android
- Flush DNS on macOS: `sudo dscacheutil -flushcache`
- Try different Wi-Fi network

**Level 3: Advanced Fixes**
- Check for VPN interference (disable temporarily)
- Verify router supports multicast/mDNS
- Use cloud relay as fallback

### Problem: "Connection Keeps Dropping"

**Symptoms**: Devices connect then disconnect frequently

**Diagnostic Steps**:
1. Check Wi-Fi signal strength on both devices
2. Monitor connection logs in both apps
3. Test during different times of day

**Solutions**:
- Update router firmware
- Change Wi-Fi channel (avoid 1, 6, 11 congestion)
- Increase router's multicast rate
- Disable Wi-Fi power saving on devices

### Problem: "Cloud Relay Not Working"

**Symptoms**: LAN sync fails and cloud fallback doesn't activate

**Diagnostic Steps**:
```bash
# Test relay server connectivity
curl -I https://hypo-relay-staging.fly.dev/health

# Should return HTTP 200 OK
```

**Solutions**:
- Check internet connectivity on both devices
- Verify relay server status at status.hypo.app
- Clear app cache and restart
- Re-pair devices to refresh cloud credentials

---

## ⏱️ Performance Issues

### Problem: "Slow Sync (>5 seconds)"

**Symptoms**: Clipboard takes too long to sync between devices

**Performance Benchmarking**:
```
Target Performance:
- LAN Sync: <500ms (P95)
- Cloud Sync: <3s (P95)
- History Load: <1s
```

**Diagnostic Steps**:

1. **Measure Actual Performance**
   - macOS: Menu Bar → Debug → Performance Monitor
   - Android: Settings → Developer Options → Sync Performance
   
2. **Network Speed Test**
   ```bash
   # Test local network speed between devices
   iperf3 -s  # On one device
   iperf3 -c <target-ip>  # On other device
   ```

3. **Check Resource Usage**
   - macOS: Activity Monitor → Hypo CPU/Memory usage
   - Android: Settings → Battery → App usage details

**Solutions by Cause**:

**Network Bottleneck**:
- Switch to 5GHz Wi-Fi
- Reduce network traffic from other devices
- Use ethernet connection for router
- Update router firmware

**Device Performance**:
- Close other memory-intensive apps
- Restart devices to clear RAM
- Check available storage space
- Update device OS

**App Configuration**:
- Reduce history size (Settings → History → Limit to 100)
- Lower image quality (Settings → Sync → Compress images)
- Disable unnecessary content types

### Problem: "High Battery Usage (Android)"

**Target**: <2% battery drain per day

**Diagnostic Steps**:
```bash
# Check actual battery usage
adb shell dumpsys batterystats | grep hypo

# Check wake locks
adb shell dumpsys power | grep -i wake
```

**Solutions**:

**Optimize Sync Settings**:
- Settings → Sync → Adaptive mode (reduces frequency when idle)
- Disable sync during battery saver mode
- Reduce history retention period

**System-Level Optimization**:
- Ensure Doze mode whitelisting
- Check for background app refresh settings
- Monitor for other apps causing wake locks

### Problem: "High Memory Usage"

**Symptoms**: App using >100MB RAM consistently

**Memory Profiling**:
- macOS: Instruments → Memory profiling
- Android: Android Studio → Memory Profiler

**Solutions**:
- Clear clipboard history regularly
- Reduce image cache size
- Restart app weekly
- Check for memory leaks (report to developers)

---

## 📱 Platform-Specific Issues

### macOS Issues

#### Problem: "Menu Bar Icon Missing"

**Causes**: App crashed or permission denied

**Solutions**:
```bash
# Check if process is running
ps aux | grep Hypo

# Restart from command line
open /Applications/Hypo.app

# Reset preferences if corrupted
defaults delete com.hypo
```

#### Problem: "Clipboard Access Denied"

**Symptoms**: App can't read/write clipboard

**Fix Accessibility Permission**:
```
System Settings → Privacy & Security → Accessibility
→ Remove Hypo → Re-add Hypo → Restart app
```

**Alternative Method**:
```bash
# Reset TCC database (requires SIP disabled)
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "DELETE FROM access WHERE client='com.hypo.HypoApp';"
```

#### Problem: "Notarization Issues"

**Symptoms**: "App cannot be verified" error

**Solutions**:
```bash
# Remove quarantine attribute
sudo xattr -rd com.apple.quarantine /Applications/Hypo.app

# Allow unidentified developer
sudo spctl --master-disable
```

### Android Issues

#### Problem: "App Killed by System"

**Symptoms**: Sync stops working after phone sleeps

**Diagnostic Commands**:
```bash
# Check if app was killed
adb shell dumpsys activity processes | grep hypo

# Check doze whitelist
adb shell dumpsys deviceidle whitelist | grep hypo
```

**Manufacturer-Specific Solutions**:

**Samsung**:
```
Settings → Device care → Battery → Background app limits
→ Never sleeping apps → Add Hypo
```

**Xiaomi (MIUI)**:
```
Settings → Apps → Manage apps → Hypo
→ Other permissions → Display pop-up windows while running in background
```

**OnePlus**:
```
Settings → Battery → Battery optimization → Advanced optimization
→ Sleep standby optimization → Off for Hypo
```

**Huawei**:
```
Settings → Battery → More battery settings → Protected apps → Hypo
```

#### Problem: "Notification Not Persistent"

**Symptoms**: Sync service notification disappears

**Solutions**:
```bash
# Check notification channel settings
adb shell cmd notification allow_listener com.hypo.clipboard

# Reset notification permissions
adb shell pm revoke com.hypo.clipboard android.permission.POST_NOTIFICATIONS
adb shell pm grant com.hypo.clipboard android.permission.POST_NOTIFICATIONS
```

#### Problem: "ClipboardManager Access Issues"

**Symptoms**: App can't monitor clipboard changes

**API Level Considerations**:
- API 29+: Use OnPrimaryClipChangedListener
- API 28-: Polling required (less efficient)

**Solutions**:
```bash
# Check API level
adb shell getprop ro.build.version.sdk

# Grant clipboard permission (if available)
adb shell pm grant com.hypo.clipboard android.permission.READ_CLIPBOARD
```

---

## 🔒 Security & Encryption Issues

### Problem: "Encryption Key Mismatch"

**Symptoms**: "Decryption failed" errors, garbled content

**Diagnostic Steps**:
1. Check both devices show same key fingerprint
2. Verify system clocks are synchronized
3. Check for pairing corruption

**Solutions**:

**Re-generate Encryption Keys**:
```
1. Both devices: Settings → Security → Reset encryption keys
2. Re-pair devices using QR code or remote pairing
3. Test sync with simple text
```

**Manual Key Reset** (Advanced):
```bash
# macOS: Clear keychain entries
security delete-generic-password -s "Hypo-DeviceKey" -a "$(whoami)"

# Android: Clear encrypted preferences
adb shell pm clear com.hypo.clipboard
```

### Problem: "Certificate Pinning Failures"

**Symptoms**: Cloud sync fails with SSL errors

**Diagnostic Steps**:
```bash
# Test SSL connection to relay
openssl s_client -connect hypo-relay-staging.fly.dev:443 -servername hypo-relay-staging.fly.dev

# Check certificate fingerprint
echo | openssl s_client -connect hypo-relay-staging.fly.dev:443 2>/dev/null | openssl x509 -fingerprint -noout -sha256
```

**Solutions**:
- Update app to latest version (new certificates)
- Check system date/time is correct
- Clear app cache and restart
- Temporarily disable other VPN/proxy connections

---

## 🧪 Testing & Diagnostics

### Debug Mode Activation

**macOS**:
```bash
# Enable debug logging
defaults write com.hypo debugLogging -bool true

# View logs
tail -f ~/Library/Logs/Hypo/debug.log
```

**Android**:
```bash
# Enable developer options
adb shell settings put global development_settings_enabled 1

# Enable debug mode in app
adb shell am start -n com.hypo.clipboard/.MainActivity --ez debug_mode true
```

### Network Diagnostics

**LAN Discovery Testing**:
```bash
# macOS: Test Bonjour service discovery
dns-sd -B _hypo._tcp local.

# Should show discovered Android devices
```

**Port Connectivity**:
```bash
# Test specific port connectivity
nc -v <target-ip> <port>

# Scan for Hypo services
nmap -p 1024-65535 <target-ip>
```

### Performance Profiling

**Sync Latency Measurement**:
1. Enable performance logging in both apps
2. Copy test content multiple times
3. Analyze logs for timing data
4. Compare against benchmarks

**Memory Leak Detection**:
```bash
# macOS: Use Instruments
instruments -t "Leaks" -D leak_trace.trace /Applications/Hypo.app

# Android: Use memory profiler
adb shell am start -n com.hypo.clipboard/.MainActivity --es profiling memory
```

### Log Collection

**Automated Log Collection**:
```bash
#!/bin/bash
# collect_logs.sh - Gather diagnostic information

echo "Collecting Hypo diagnostic logs..."

# System information
echo "=== System Info ===" > hypo_diagnostics.txt
uname -a >> hypo_diagnostics.txt
sw_vers >> hypo_diagnostics.txt  # macOS only

# Network configuration
echo "=== Network Config ===" >> hypo_diagnostics.txt
ifconfig >> hypo_diagnostics.txt
netstat -rn >> hypo_diagnostics.txt

# App logs
echo "=== App Logs ===" >> hypo_diagnostics.txt
tail -100 ~/Library/Logs/Hypo/*.log >> hypo_diagnostics.txt

# Process information
echo "=== Process Info ===" >> hypo_diagnostics.txt
ps aux | grep -i hypo >> hypo_diagnostics.txt

echo "Logs collected in hypo_diagnostics.txt"
```

---

## 📞 Getting Help

### Before Contacting Support

**Gather This Information**:
1. **Device Details**:
   - macOS version and hardware model
   - Android version and device model
   - Hypo app version on both devices

2. **Problem Description**:
   - Exact steps to reproduce
   - Error messages (screenshots helpful)
   - When the problem started
   - Frequency (always/sometimes/rare)

3. **Network Environment**:
   - Router model and firmware version
   - ISP and connection type
   - Other devices on network
   - VPN or proxy usage

4. **Log Files**:
   - Recent app logs from both devices
   - System logs if app crashes
   - Network diagnostic output

### Self-Help Resources

**Documentation**:
- [User Guide](USER_GUIDE.md): Complete feature documentation
- [Installation Guide](INSTALLATION.md): Setup instructions
- [Developer Guide](DEVELOPER_GUIDE.md): Technical details

**Community Resources**:
- GitHub Issues: Search existing problems and solutions
- Community Forum: User tips and workarounds
- Wiki: Community-maintained troubleshooting tips

### Contact Support

**GitHub Issues** (Preferred for bugs):
```
https://github.com/hypo-app/hypo/issues/new?template=bug_report.md
```

**Email Support**:
- Technical Issues: support@hypo.app
- Security Concerns: security@hypo.app
- General Questions: hello@hypo.app

**Response Times**:
- Critical bugs: Within 24 hours
- General issues: Within 2 business days
- Feature requests: Acknowledged within 1 week

---

## 🔄 Recovery Procedures

### Complete Reset (Last Resort)

**When Nothing Else Works**:

1. **Backup Important Data**:
   ```bash
   # Export clipboard history (if accessible)
   # Settings → Export → Save clipboard history
   ```

2. **Complete Uninstall**:
   ```bash
   # Follow uninstallation steps in INSTALLATION.md
   # Remove all preferences and data
   ```

3. **Fresh Installation**:
   ```bash
   # Download latest version
   # Follow installation guide exactly
   # Don't restore old settings initially
   ```

4. **Gradual Configuration**:
   - Test basic sync before changing settings
   - Re-pair devices from scratch
   - Slowly add back custom configurations

### Factory Reset Simulation

**macOS**:
```bash
# Stop app
killall Hypo

# Remove all Hypo data
rm -rf ~/Library/Preferences/com.hypo.*
rm -rf ~/Library/Application\ Support/Hypo
rm -rf ~/Library/Logs/Hypo

# Clear keychain
security delete-generic-password -s "Hypo" 2>/dev/null

# Restart app
open /Applications/Hypo.app
```

**Android**:
```bash
# Clear all app data
adb shell pm clear com.hypo.clipboard

# Restart app
adb shell am start -n com.hypo.clipboard/.MainActivity
```

---

**Troubleshooting Guide Version**: 1.0  
**Compatible with Hypo**: 0.1.0 Beta  
**Last Updated**: October 11, 2025  
**For Additional Help**: support@hypo.app