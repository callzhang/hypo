# Clipboard Sync Bug Report: Android-to-macOS Clipboard Synchronization Issues

**Date**: November 16, 2025  
**Last Updated**: November 23, 2025 - 16:50 UTC  
**Status**: ✅ **RESOLVED** – Both plaintext and encrypted cloud sync working  
**Severity**: Critical – Cloud path was unusable, now fixed  
**Priority**: P0 – ✅ Complete

---

## Simulation Test Results (Nov 21, 2025)

| Test | Mode | Envelope ID | Result | Notes |
|------|------|-------------|--------|-------|
| Test 1 | Plaintext + LAN | `5e6d982d-…` | ✅ PASS | Received via LAN server; origin=`lan`; history updated |
| Test 2 | Plaintext + Cloud | `727edf6b-…` | ❌ FAIL | macOS cloud connection established (`handleOpen`, `receiveNext()` logged) but **no** `Binary data received` entries; no HTTP errors |
| Test 3 | Encrypted + LAN | `cdb7c553-…` | ✅ PASS | Received via LAN server; origin=`lan`; history updated |
| Test 4 | Encrypted + Cloud | `56eb312c-…` | ❌ FAIL | Same as Test 2: connection established, no frames delivered |

**Target macOS Device ID:** `007E4A95-0E1A-4B10-91FA-87942EFAA68E`

---

## Key Findings
- LAN pipeline (plaintext + encrypted) works end-to-end.
- **Root Cause Identified**: Server's `validate_encryption_block()` rejected plaintext messages (empty nonce/tag failed validation).
- **Root Cause Identified**: macOS wasn't connecting to cloud relay (ConnectionStatusProber only checked health, didn't connect).
- **Fixes Applied**:
  1. Server: Updated `validate_encryption_block()` to handle plaintext (empty nonce/tag = plaintext, skip encryption validation).
  2. macOS: Updated `ConnectionStatusProber` to actually call `cloudTransport.connect()` instead of just checking health.
- **Status**: macOS now registered with relay server (device ID: `007E4A95-0E1A-4B10-91FA-87942EFAA68E`).

---

## Backend Investigation Request

**Envelope IDs for Relay Log Analysis:**
- **Test 2 (Plaintext Cloud)**: `c2a46906-…` (latest enhanced test run)
- **Test 4 (Encrypted Cloud)**: `42a61b16-…` (latest enhanced test run)
- Previous test run IDs (for reference): `727edf6b-…`, `56eb312c-…`

**Target macOS Device ID:** `007E4A95-0E1A-4B10-91FA-87942EFAA68E`

**Questions for Backend Team:**
1. Did these envelope IDs (`c2a46906-…`, `42a61b16-…`) arrive at the relay?
2. Was macOS device `007E4A95-0E1A-4B10-91FA-87942EFAA68E` registered/connected when the messages arrived?
   - Look for: `"Registered device: 007E4A95-..."`
3. Did the server attempt to route them to that device_id?
   - Look for: `"Routing message from c7bd7e23-... to target device: 007E4A95-..."`
   - Look for: `"Attempting to send to device: 007E4A95-..."`
4. Why did routing fail?
   - Look for: `"Target device 007E4A95-... not connected, message not delivered"` OR
   - Look for: `"Device 007E4A95-... not found in sessions. Available: [...]"`
5. What devices were registered at the time?
   - Look for: `"Registered devices: [...]"` in `send_binary` logs
6. Are cloud messages being broadcast to LAN connections instead of the cloud WebSocket channel?

**macOS Client Logs:**
- Enhanced logging now captures HTTP status codes, response headers, close codes, and error details
- Logs available in `/tmp/hypo_debug.log` for analysis
- Will capture detailed diagnostics on next test run

---

## macOS Client Actions

### ✅ Completed
1. **Enhanced HTTP Response Logging** - `didCompleteWithError` now captures:
   - HTTP status code and status text
   - All response headers (detailed per-header logging)
   - Request URL and headers
   - Error domain, code, and all UserInfo fields
   - Connection state (last activity, retry count)
   
2. **Enhanced WebSocket Close Logging** - `didCloseWith` now captures:
   - Close code (raw value and human-readable meaning)
   - Close reason (if provided)
   - HTTP response details (for cloud connections)
   - Connection timing and retry state
   
3. **Exponential Backoff** - Implemented for cloud receive failures:
   - Retry sequence: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s
   - Max 8 retries before giving up
   - Prevents hammering the relay
   
4. **Query Parameter Handling** - Preserved for cloud connections:
   - Query parameters kept for wss:// connections
   - Only removed for ws:// (LAN) where they break handshake

### ✅ Completed
- [x] Server: Fixed `validate_encryption_block()` to handle plaintext messages
- [x] Server: Deployed to Fly.io
- [x] macOS: Fixed `ConnectionStatusProber` to actually connect to cloud relay
- [x] macOS: Registered with relay server (device ID: `007E4A95-0E1A-4B10-91FA-87942EFAA68E`)
- [x] Test 1: Plaintext + Cloud ✅ PASS (Nov 23, 16:37 UTC)
- [x] Test 2: Encrypted + Cloud ✅ PASS (Nov 23, 16:47 UTC)

### ✅ Test Results (Nov 23, 2025)
- **Test 1 (Plaintext Cloud)**: Message received, decoded, added to history. Origin correctly identified as `cloud`.
- **Test 2 (Encrypted Cloud)**: Message received, decrypted, decoded, added to history. Origin correctly identified as `cloud`.
- **Status**: Both tests passing. Cloud relay sync fully functional.

---

## Reference Commands
```bash
# Monitor macOS logs during tests
log stream --predicate 'process == "HypoMenuBar"' --style syslog

tail -f /tmp/hypo_debug.log | grep -E "(LanWebSocketTransport|origin|Test [1-4])"
```
