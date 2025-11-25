# Log Checking Guide for Testing

**Last Updated:** November 25, 2025  
**Purpose:** Guide for checking logs on Android and macOS to debug test failures and verify message reception.

## Overview

When running integration tests (e.g., `tests/test-sync-matrix.sh`), you may need to manually check logs to verify message reception, debug failures, or understand the message flow. This guide provides commands and patterns for checking logs on both platforms.

---

## Android Log Checking

### Basic Commands

#### 1. View Recent Logs (Last 200 lines)
```bash
adb -s <device_id> logcat -d -t 200
```

#### 2. Filter by Process (Hypo Clipboard App)
```bash
# Get the app's PID first
adb -s <device_id> shell pidof -s com.hypo.clipboard.debug

# Then filter by PID
adb -s <device_id> logcat --pid=$(adb -s <device_id> shell pidof -s com.hypo.clipboard.debug)
```

#### 3. Real-time Log Monitoring
```bash
adb -s <device_id> logcat -c  # Clear buffer first
adb -s <device_id> logcat      # Monitor in real-time
```

### Key Log Patterns for Message Reception

#### Cloud WebSocket Messages
```bash
# Check for onMessage() calls from cloud relay
adb -s <device_id> logcat -d | grep -E "🔥🔥🔥.*onMessage.*wss://hypo.fly.dev"

# Check for decoded envelopes
adb -s <device_id> logcat -d | grep -E "✅ Decoded envelope.*type=CLIPBOARD"

# Check for handler processing
adb -s <device_id> logcat -d | grep -E "IncomingClipboardHandler.*✅.*Decoded clipboard event"
```

#### LAN WebSocket Messages
```bash
# Check for binary frames received on LAN server
adb -s <device_id> logcat -d | grep -E "LanWebSocketServer.*Binary frame received"

# Check for handler invocation
adb -s <device_id> logcat -d | grep -E "TransportManager.*Invoking incoming clipboard handler"

# Check for decoded envelopes
adb -s <device_id> logcat -d | grep -E "✅ Decoded envelope.*type=CLIPBOARD"
```

#### Database Storage
```bash
# Check for database insertions
adb -s <device_id> logcat -d | grep -E "Upserting item|ClipboardRepository.*💾"

# Query database directly
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview, created_at FROM clipboard_items ORDER BY created_at DESC LIMIT 10;'"
```

#### Decryption Failures
```bash
# Check for decryption errors
adb -s <device_id> logcat -d | grep -E "❌.*Failed.*decode|BAD_DECRYPT|IncomingClipboardHandler.*❌"

# Check for missing key warnings
adb -s <device_id> logcat -d | grep -E "MissingKey|key not found|decryption.*failed"
```

### Complete Message Flow Check

For a specific test case (e.g., "Case 2: Plaintext Cloud Android"):

```bash
# 1. Check if message was received (onMessage call)
adb -s <device_id> logcat -d | grep -E "Case 2:|🔥🔥🔥.*onMessage"

# 2. Check if envelope was decoded
adb -s <device_id> logcat -d | grep -E "Case 2:|✅ Decoded envelope"

# 3. Check if handler processed it
adb -s <device_id> logcat -d | grep -E "Case 2:|IncomingClipboardHandler.*✅"

# 4. Check if stored in database
adb -s <device_id> logcat -d | grep -E "Case 2:|Upserting item"

# 5. Verify in database
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview FROM clipboard_items WHERE preview LIKE \"%Case 2:%\" LIMIT 1;'"
```

### WebSocket Connection Status

```bash
# Check cloud WebSocket connection
adb -s <device_id> logcat -d | grep -E "RelayWebSocketClient|CloudRelay|hypo.fly.dev|connected.*cloud|cloud.*connected"

# Check LAN WebSocket connection
adb -s <device_id> logcat -d | grep -E "LanWebSocketClient|ws://|LAN.*connected|connected.*LAN"
```

---

## macOS Log Checking

### Basic Commands

#### 1. Unified Logging (Recommended)
```bash
# View recent logs for HypoMenuBar process
log show --predicate 'process == "HypoMenuBar"' --last 5m --style compact --info

# Real-time monitoring
log stream --predicate 'process == "HypoMenuBar"' --style compact --info
```

#### 2. Debug Log File
```bash
# View debug log file (if configured)
tail -f /tmp/hypo_debug.log

# Search for specific case
grep "Case 2:" /tmp/hypo_debug.log
```

#### 3. Console.app
- Open Console.app
- Filter by process: `HypoMenuBar`
- Search for keywords: `CLIPBOARD`, `Received`, `Inserted entry`

### Key Log Patterns for Message Reception

#### Cloud Relay Messages
```bash
# Check for received messages
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "CloudRelayTransport.*Received|CLIPBOARD.*received"

# Check for decoded messages
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "CLIPBOARD DECODED|SyncEngine.*✅"

# Check for database insertions
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "Inserted entry|HistoryStore.*insert"
```

#### LAN Messages
```bash
# Check for LAN server reception
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "LanWebSocketServer.*received|LAN.*message"

# Check for client connections
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "LanWebSocketTransport.*connected|LAN.*connected"
```

#### Decryption Failures
```bash
# Check for decryption errors
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "decryption.*failed|BAD_DECRYPT|❌.*decode"

# Check for missing key errors
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "MissingKey|key.*not.*found"
```

### Complete Message Flow Check

For a specific test case:

```bash
# 1. Check if message was received
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "Case 2:|Received clipboard"

# 2. Check if decoded
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "Case 2:|CLIPBOARD DECODED"

# 3. Check if inserted
log show --predicate 'process == "HypoMenuBar"' --last 5m | grep -E "Case 2:|Inserted entry"
```

---

## Backend Log Checking

### Cloud Relay Logs (Fly.io)

```bash
# View recent backend logs
flyctl logs --app hypo --limit 100

# Filter for routing decisions
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\]|\[SEND_BINARY\]"

# Check connected devices
curl -s https://hypo.fly.dev/health | jq '.connected_devices'

# Check session info
curl -s https://hypo.fly.dev/health | jq '.session_info'
```

### Key Backend Log Patterns

#### Message Routing
```bash
# Check routing decisions
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\].*targeting device|Successfully routed"

# Check for routing failures
flyctl logs --app hypo --limit 100 | grep -E "Device.*not found|routing.*failed"
```

#### WebSocket Connections
```bash
# Check connection/disconnection events
flyctl logs --app hypo --limit 100 | grep -E "WebSocket.*connected|WebSocket.*disconnected|device.*registered"
```

---

## Test Script Detection Logic

The `tests/test-sync-matrix.sh` script uses the following detection priority:

1. **Database Query** (Most Reliable)
   - Checks SQLite database for case number in preview/content
   - Commands: `sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db`

2. **Handler Success Logs**
   - Looks for: `IncomingClipboardHandler.*✅.*Decoded clipboard event`
   - Or: `Upserting item.*Case X:`

3. **Case Pattern in Logs**
   - Searches for: `Case X:` in logcat output

4. **Reception Indicators**
   - Cloud: `🔥🔥🔥.*onMessage.*CALLED` or `✅ Decoded envelope`
   - LAN: `LanWebSocketServer.*Binary frame received` or `TransportManager.*Invoking`

### Manual Verification

If the test script reports a failure but you suspect the message was received:

```bash
# 1. Check database directly
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview, created_at FROM clipboard_items WHERE preview LIKE \"%Case X:%\" ORDER BY created_at DESC LIMIT 1;'"

# 2. Check logs for reception
adb -s <device_id> logcat -d -t 500 | grep -E "Case X:|onMessage|Decoded envelope|Upserting"

# 3. Check for errors
adb -s <device_id> logcat -d -t 500 | grep -E "Case X:|❌.*Failed|BAD_DECRYPT"
```

---

## Common Issues and Solutions

### Issue: Test shows "No onMessage() call" but message was received

**Solution:** Check database directly - messages may be received but not logged with the expected pattern.

```bash
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%Case X:%\";'"
```

### Issue: Decryption failures (BAD_DECRYPT)

**Possible Causes:**
1. Key rotation - devices were re-paired and key changed
2. Wrong key used in test script
3. Key not found on receiver

**Solution:**
1. Re-pair devices to get new key
2. Update test script to use current key from keychain
3. Check key exists: `security find-generic-password -w -s 'com.hypo.clipboard.keys' -a <device_id>`

### Issue: Messages received but not detected by test script

**Solution:** The test script may be checking the wrong time window. Check logs manually:

```bash
# Check all recent messages
adb -s <device_id> logcat -d -t 1000 | grep -E "Case [0-9]:|onMessage|Decoded|Upserting"

# Check database for all recent entries
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview, created_at FROM clipboard_items ORDER BY created_at DESC LIMIT 10;'"
```

---

## Quick Reference

### Android - One-liner for Complete Check
```bash
adb -s <device_id> logcat -d -t 500 | grep -E "Case [0-9]:|onMessage|Decoded|Upserting|❌.*Failed" && \
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 5;'"
```

### macOS - One-liner for Complete Check
```bash
log show --predicate 'process == "HypoMenuBar"' --last 5m --style compact | grep -E "Case [0-9]:|CLIPBOARD|Inserted entry|❌.*Failed"
```

### Backend - One-liner for Routing Check
```bash
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\]|\[SEND_BINARY\]" && \
curl -s https://hypo.fly.dev/health | jq '.connected_devices'
```

---

## Tips

1. **Clear log buffers before testing:**
   ```bash
   adb -s <device_id> logcat -c  # Android
   # macOS logs are automatically rotated
   ```

2. **Use timestamps to correlate:**
   - Test script prints timestamps: `Case X: ... HH:MM:SS`
   - Search logs for that timestamp to find the exact message

3. **Check multiple sources:**
   - Database (most reliable)
   - Handler logs (processing confirmation)
   - Reception logs (onMessage, binary frames)

4. **For encrypted messages:**
   - Check decryption logs separately
   - Verify key exists and is correct
   - Check for key rotation warnings

---

**Related Documentation:**
- `docs/testing/lan_manual.md` - LAN sync manual testing
- `docs/testing/cloud_manual.md` - Cloud sync manual testing
- `docs/bugs/android_cloud_sync_status.md` - Android sync issues and fixes

