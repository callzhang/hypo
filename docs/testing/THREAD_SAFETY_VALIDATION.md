# Thread Safety Validation Guide

**Issue**: macOS app crashes on concurrent WebSocket frame processing (Issue 7)  
**Fix**: Buffer snapshot + NSLock protection (Fix 3)  
**Date**: November 16, 2025

---

## Overview

This guide provides comprehensive testing strategies to validate the thread-safety fixes applied to `LanWebSocketServer.ConnectionContext` buffer operations.

---

## Testing Strategies

### 1. Unit Tests (XCTest)

**Location**: `macos/Tests/HypoAppTests/LanWebSocketServerBufferTests.swift`

**Run tests**:
```bash
cd macos
swift test --filter LanWebSocketServerBufferTests
```

**What it validates**:
- Concurrent frame processing doesn't crash
- Server handles rapid incoming data
- No data races in frame processing

---

### 2. Thread Sanitizer (TSan)

**Purpose**: Detects data races and threading issues at runtime

**Enable in Xcode**:
1. Open `macos/HypoApp.xcworkspace` in Xcode
2. Select scheme → Edit Scheme
3. Run → Diagnostics → Enable "Thread Sanitizer"
4. Run the app

**Or use command line**:
```bash
./macos/scripts/run-with-thread-sanitizer.sh
```

**What to look for**:
- `WARNING: ThreadSanitizer: data race` messages
- Any warnings about concurrent access to `buffer`
- Lock contention warnings

**Expected result**: No data race warnings ✅

---

### 3. Stress Testing

**Automated stress test**:
```bash
./macos/scripts/stress-test-buffer.sh
```

**Manual stress test**:
```bash
# Terminal 1: Run macOS app
cd macos && swift build -c release
.build/release/HypoMenuBar

# Terminal 2: Rapid clipboard changes on Android
for i in {1..100}; do
    adb shell "service call clipboard 1 i32 1 s16 'text/plain' s16 'StressTest_${i}'"
    sleep 0.1
done
```

**What to monitor**:
- App doesn't crash
- All clipboard syncs received
- No `Data.subscript` errors in logs

---

### 4. Integration Testing

**Full end-to-end test**:
```bash
./tests/test-clipboard-sync-emulator-auto.sh
```

**What it validates**:
- Pairing works
- Clipboard sync works bidirectionally
- No crashes during sync
- All frames processed correctly

---

### 5. Log Analysis

**Monitor for issues**:
```bash
# Watch for buffer-related errors
log show --predicate 'process == "HypoMenuBar"' --last 10m | \
  grep -i "buffer\|subscript\|index\|race"

# Check for successful syncs
log show --predicate 'process == "HypoMenuBar"' --last 10m | \
  grep -E "(Received clipboard|Decoded clipboard)"

# Count success vs failures
SUCCESS=$(log show --predicate 'process == "HypoMenuBar"' --last 10m | \
  grep -c "Decoded clipboard" || echo "0")
FAILED=$(log show --predicate 'process == "HypoMenuBar"' --last 10m | \
  grep -c "Failed to handle" || echo "0")
echo "Success: $SUCCESS, Failed: $FAILED"
```

---

## Validation Checklist

### Pre-Test Setup
- [ ] macOS app rebuilt with latest fixes
- [ ] Android app rebuilt with production server URL
- [ ] Devices/emulator paired successfully
- [ ] Monitoring scripts ready

### During Test
- [ ] Small text sync (< 100 bytes) - works ✅
- [ ] Medium text sync (1-10 KB) - works ✅
- [ ] Large text sync (> 100 KB) - works ✅
- [ ] Rapid syncs (10+ in quick succession) - works ✅
- [ ] Network instability - handles gracefully ✅

### Post-Test Verification
- [ ] No crash reports in `~/Library/Logs/DiagnosticReports`
- [ ] No `Data.subscript` errors in logs
- [ ] All clipboard syncs received successfully
- [ ] Thread Sanitizer shows no data races (if enabled)

---

## Expected Behavior

### Success Pattern
```
📥 Received clipboard data from connection: [UUID], [N] bytes
📥 Processing incoming clipboard data ([N] bytes)
✅ Decoded clipboard: type=text
✅ Added to history from device: [Device Name]
```

### Failure Pattern (Should NOT appear)
```
❌ Failed to handle incoming clipboard: [error]
EXC_BREAKPOINT (SIGTRAP)
Data.subscript.getter
WARNING: ThreadSanitizer: data race
```

---

## Performance Metrics

**Monitor these during stress tests**:

```bash
# CPU and memory usage
ps aux | grep HypoMenuBar | awk '{print "CPU: "$3"% Memory: "$4"%"}'

# Buffer operations count
log show --predicate 'process == "HypoMenuBar"' --last 10m | \
  grep -c "snapshotBuffer\|appendToBuffer\|dropPrefix"

# Sync latency
# Measure time from Android copy to macOS receive
```

---

## Troubleshooting

### If tests fail:

1. **Capture crash report**:
   ```bash
   find ~/Library/Logs/DiagnosticReports -name "*HypoMenuBar*.ips" -mmin -5
   ```

2. **Capture logs**:
   ```bash
   log show --predicate 'process == "HypoMenuBar"' --last 10m > /tmp/hypo_crash_logs.txt
   ```

3. **Check Thread Sanitizer output**:
   - Look for specific data race locations
   - Check which threads are accessing the buffer
   - Verify lock acquisition order

4. **Review buffer operations**:
   - Check if `snapshotBuffer()` is being called correctly
   - Verify `dropPrefix()` is called after frame processing
   - Ensure `appendToBuffer()` is protected by lock

---

## Next Steps After Validation

**If validation passes**:
1. ✅ Mark Issue 7 as "RESOLVED" in bug report
2. ✅ Remove temporary debug logging (if added)
3. ✅ Document fix in changelog
4. ✅ Consider adding more unit tests for edge cases

**If issues persist**:
1. ⚠️ Capture detailed crash logs
2. ⚠️ Note specific scenario that triggers crash
3. ⚠️ Check if it's a different race condition
4. ⚠️ Review lock acquisition patterns

---

## References

- [Apple: Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)
- [Swift: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [Thread Sanitizer Documentation](https://github.com/google/sanitizers/wiki/ThreadSanitizerAlgorithm)

---

**Last Updated**: November 16, 2025

