# LAN Discovery Diagnostic Tool

## Usage

```bash
./scripts/diagnose-lan-discovery.sh [android_device_id]
```

If no device ID is provided, it will auto-detect the Xiaomi device or use the first connected device.

## What It Captures

### Android Logs:
- **Discovery Events**: Service found/resolved/lost events
- **Connection Attempts**: LAN WebSocket connection attempts to macOS
- **Transport Status**: LAN vs CLOUD transport activations
- **Connection Failures**: Failed connection attempts and retries

### macOS Logs:
- **Bonjour Advertising**: Service registration/stopping events
- **Connection Status**: Active connections and discovered peers

## What to Look For

### 1. **Discovery Stability**
- ✅ **Good**: Regular "Service found" → "Service resolved" events
- ⚠️ **Bad**: Frequent "onServiceLost" or "reported as lost" events
- **Conclusion**: If services are frequently lost, mDNS/Bonjour is unstable

### 2. **Connection Attempts**
- ✅ **Good**: Connection attempts succeed, transport switches to LAN
- ⚠️ **Bad**: Connection attempts fail, transport stays on CLOUD
- **Conclusion**: If LAN connections fail, check network/firewall

### 3. **Timing Correlation**
- Check if "Service lost" events correlate with connection failures
- Check if macOS Bonjour stops advertising when Android reports loss
- **Conclusion**: If macOS is still advertising but Android reports loss, it's an NSD issue

### 4. **Transport Preference**
- Count LAN vs CLOUD transport activations
- **Conclusion**: If CLOUD > LAN, system is falling back to cloud too often

## Expected Patterns

### Healthy LAN Connection:
```
Service found → Service resolved → Connection attempt → Connection opened → Transport: LAN
```

### Problem Pattern:
```
Service found → Service resolved → onServiceLost → Connection attempt fails → Transport: CLOUD
```

## Common Issues & Solutions

### Issue 1: Services Frequently Lost
**Symptoms**: More "onServiceLost" than "Service found" events
**Possible Causes**:
- macOS Bonjour service stopping/restarting
- Network instability
- Android NSD timeout too aggressive
**Solution**: Check macOS Bonjour logs for service registration issues

### Issue 2: Connection Attempts Fail
**Symptoms**: Connection attempts to `ws://10.0.0.107:7010` fail
**Possible Causes**:
- macOS WebSocket server not running
- Firewall blocking port 7010
- Network routing issues
**Solution**: Verify macOS server is running and port is accessible

### Issue 3: Cloud Transport Preferred
**Symptoms**: CLOUD transport activations > LAN
**Possible Causes**:
- LAN connection timeout too short (3 seconds)
- Connection failures trigger cloud fallback
- Discovery not working reliably
**Solution**: Increase LAN timeout or fix discovery issues

## Report Analysis

The script generates a report with:
1. Event counts and timeline
2. Pattern detection (warnings for issues)
3. Correlation analysis between events

Look for the "ANALYSIS" section in the report for automated issue detection.

