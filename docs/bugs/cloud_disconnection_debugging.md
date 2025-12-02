# Cloud Disconnection Debugging Guide

## Event-Driven Reconnection with Exponential Backoff

The cloud connection now uses **event-driven reconnection** with exponential backoff (1s → 128s+):
- When `onClosed`/`onFailure` fires, it **immediately** triggers `ensureConnection()`
- Exponential backoff is applied **before** starting the connection attempt (not during retry loop)
- Backoff resets to 0 on successful connection
- No polling or periodic retries - everything is event-driven

## Logs to Look For When Cloud Disconnects

### 1. Disconnection Events (Primary Indicators)

**When connection closes normally:**
```
🔴 WebSocket closed: code=..., reason=..., type=..., url=wss://hypo.fly.dev/ws, cloud=true
📢 onClosed: completed closedSignal, updated TransportManager=true, event-driven reconnection will be triggered
🔄 Event-driven: triggering ensureConnection() after onClosed
```

**When connection fails:**
```
❌ Connection failed to wss://hypo.fly.dev/ws: ...
📈 Connection failed, consecutive failures: 1
🔄 Event-driven: triggering ensureConnection() after onFailure
```

**When connection resets (RST packet):**
```
⚠️ Connection reset by server (RST packet) - treating as normal close
📢 onFailure (RST): completed closedSignal, updated TransportManager=true, event-driven reconnection will be triggered
🔄 Event-driven: triggering ensureConnection() after onFailure (RST)
```

### 2. Event-Driven Reconnection (What Happens After Disconnection)

**Immediate reconnection trigger:**
```
🔄 Event-driven: triggering ensureConnection() after onClosed
🔌 ensureConnection() starting new connection job (isCloud=true, url=wss://..., failures=1)
```

**Exponential backoff applied before connection attempt:**
```
⏳ Applying exponential backoff: 1000ms (consecutive failures: 1)
⏳ Applying exponential backoff: 2000ms (consecutive failures: 2)
⏳ Applying exponential backoff: 4000ms (consecutive failures: 3)
...
⏳ Applying exponential backoff: 128000ms (consecutive failures: 9+)
```

**Connection attempt after backoff:**
```
🚀 Connecting to: wss://hypo.fly.dev/ws (cloud)
☁️ Starting cloud connection - updating state to ConnectingCloud
```

**Successful connection resets failure count:**
```
✅ Long-lived CLOUD connection established (cloud relay), reset failure count
☁️ Updating TransportManager state to ConnectedCloud, reset failure count
```

### 3. Potential Issues (What to Check)

**If reconnection doesn't happen:**
- Check if `sendQueueClosed=true` - this means client is shutting down
- Look for: `⚠️ sendQueue is closed - client is shutting down, exiting connection loop`
- Check if `connectionJob` is null or inactive

**If reconnection happens but fails:**
- Look for: `📈 Connection failed, consecutive failures: N`
- Check failure count - should increment: `1`, `2`, `3`, etc.
- Check if backoff is applied: `⏳ Applying exponential backoff: Xms`
- Check if state updates: `ConnectingCloud` → `ConnectedCloud` (on success) or stays `ConnectingCloud` (on failure)

**If connection job exits unexpectedly:**
- Look for: `❌ Error in connection loop: ...`
- Check if `ensureConnection()` is called after error
- Check if failure count is incremented

## Current Reconnection Architecture

### How It Works Now (Event-Driven)

1. **Disconnection Event:**
   - `onClosed` or `onFailure` fires
   - Immediately sets state to `ConnectingCloud`
   - Launches coroutine to call `ensureConnection()` after 100ms delay

2. **Reconnection Attempt:**
   ```
   ensureConnection() {
     if (consecutiveFailures > 0) {
       delay(exponentialBackoff)  // 1s → 2s → 4s → ... → 128s
     }
     if (connectionJob == null || !connectionJob.isActive) {
       launch {
         runConnectionLoop()  // Try to connect once
       }
     }
   }
   ```

3. **Connection Loop:**
   ```
   runConnectionLoop() {
     // Try to connect
     if (handshake fails) {
       consecutiveFailures++
       return  // Exit - event-driven reconnection will handle retry
     }
     // Connection successful
     consecutiveFailures = 0  // Reset on success
     // Maintain connection until closed
     while (true) {
       waitForEvent()
       if (closedSignal.isCompleted) break
     }
     return  // Exit - onClosed/onFailure will trigger ensureConnection()
   }
   ```

### Key Differences from Old Design

1. **No Retry Loop:**
   - Old: `runConnectionLoop()` had outer `while` loop with retry delays
   - New: `runConnectionLoop()` tries once, exits on failure/disconnect
   - Reconnection is handled by `ensureConnection()` called from `onClosed`/`onFailure`

2. **Immediate Reconnection:**
   - Old: Retry happened after delay in retry loop
   - New: `onClosed`/`onFailure` immediately triggers `ensureConnection()`
   - Backoff is applied in `ensureConnection()` before connection attempt

3. **State Management:**
   - Old: State set to `Disconnected` on close, `ConnectingCloud` after delay
   - New: State set to `ConnectingCloud` immediately on close
   - UI shows "Connecting" during backoff, not "Disconnected"

4. **Failure Tracking:**
   - Old: `retryCount` in `runConnectionLoop()` (reset on each loop iteration)
   - New: `consecutiveFailures` at class level (persists across attempts, resets on success)

## Debugging Commands

### Check if connection is active:
```bash
adb logcat | grep -E "ensureConnection|connection job|runConnectionLoop"
```

### Check disconnection events:
```bash
adb logcat | grep -E "WebSocket closed|Connection failed|onClosed|onFailure|Event-driven"
```

### Check exponential backoff:
```bash
adb logcat | grep -E "Applying exponential backoff|consecutive failures"
```

### Check connection state changes:
```bash
adb logcat | grep -E "ConnectingCloud|ConnectedCloud|Disconnected|reset failure count"
```

### Full connection lifecycle:
```bash
adb logcat | grep -E "WebSocketTransportClient" | grep -E "cloud|Cloud|CLOUD"
```
