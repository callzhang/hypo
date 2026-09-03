# Debugging Sync Issues

## Start With the Relay's Counters

`GET https://hypo.fly.dev/status` answers the first question — did anything
actually get through — without needing either device in front of you.

```json
"messages": {
  "processed": 1698,        // arrived at the relay
  "delivered": 1502,        // handed to a connected target
  "dropped_offline": 196,   // target was not connected; discarded, there is no queue
  "receive_failures": 3     // a receiver said it could not decrypt what it got
}
```

Reading them:

- **`processed` climbing, `delivered` flat** — the sender is reaching the relay
  and the target is not connected. Check whether the receiving device is
  actually on the relay: the `connections.devices` list in the same response
  carries the device ids currently attached.
- **`dropped_offline` climbing** — same thing, counted. There is no queue: a
  message for a device that is not connected is discarded, not held. This is
  deliberate; a clipboard entry delivered half an hour late would overwrite
  whatever the user is using now.
- **`receive_failures` climbing** — the bytes arrived and the receiving app
  could not decrypt them. Usually a key mismatch: the two devices disagree about
  the pairing. The relay's log names the device and the message id.
- **All four flat while a device claims to be connected** — the sender is not
  reaching the relay at all. Its own log is the place to look; note that
  "Message confirmed (timeout, connection valid)" is optimistic and does not
  mean anything arrived.

`redis.operations` only moves during pairing — Redis holds device registrations
and pairing codes, and message forwarding does not touch it. Zero there while
messages flow is normal, not a fault.

## Connection Reset Analysis

When Android sends a message but macOS doesn't receive it, and you see a "Connection reset" error, here's what's happening:

### Timeline
1. **Android sends message** (line 995): Frame sent successfully
2. **~48 seconds later** (line 997): Connection reset occurs

### Root Cause Analysis

The backend relay server (`backend/src/handlers/websocket.rs`) handles messages as follows:

1. **When target device (macOS) is NOT connected:**
   - Server logs: `"Target device {} not connected, message not delivered"`
   - Server sends error response back to Android with:
     - `type: "error"`
     - `code: "device_not_connected"`
     - `message: "Target device {} is not connected to the relay server"`
   - **Server does NOT close the connection** - it just returns an error

2. **Connection reset after 48 seconds:**
   - This is likely a **timeout or server-side connection cleanup**
   - Backend has `keep_alive: 30 seconds` for HTTP connections
   - WebSocket connections may have different timeout behavior
   - The reset happens because the connection becomes idle or the server detects the target device is offline

### What to Check

1. **Is macOS connected to the cloud relay?**
   - Check macOS logs: `log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug`
   - Look for: `"✅ [TransportManager] Connected to cloud relay"` or `"connectedCloud"` state
   - If not connected, macOS needs to establish a WebSocket connection to `wss://hypo.fly.dev/ws`

2. **Is Android receiving error messages?**
   - Check Android logs for: `"❌ Sync error: code=device_not_connected"`
   - If you see this, the server is correctly reporting that macOS is not connected
   - Android should handle this gracefully and show an error to the user

3. **Server-side logs:**
   - Check Fly.io logs: `fly logs -a hypo-relay-staging`
   - Look for: `"Target device {} not connected, message not delivered"`
   - This confirms the server received the message but couldn't route it

### Solutions

1. **Ensure macOS is connected:**
   - macOS should auto-connect to cloud relay on startup
   - Check connection status in macOS app UI
   - If not connected, check network connectivity and firewall settings

2. **Verify device pairing:**
   - Both devices must be paired (have encryption keys)
   - Check that device IDs match between Android and macOS

3. **Check server health:**
   - Verify backend is running: `curl https://hypo.fly.dev/health`
   - Check server logs for any errors or connection issues

### Expected Behavior

- **If macOS is connected:** Message should be routed immediately
- **If macOS is NOT connected:** Server sends error response to Android, Android logs error, connection may reset after timeout
- **Connection reset is normal** when target device is offline - Android will reconnect automatically

