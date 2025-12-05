# Hypo Clipboard Sync Protocol Specification

Version: 1.0.5  
Status: Production  
Date: December 5, 2025

---

## 1. Overview

The Hypo protocol defines the message format and communication patterns for clipboard synchronization between devices. It uses WebSocket as the transport layer with JSON-encoded messages.

### Design Principles

1. **Simplicity**: Human-readable JSON for debugging
2. **Extensibility**: Metadata field allows future enhancements
3. **Security**: Encrypted payload with authentication tags
4. **Efficiency**: Minimal overhead, optional compression

---

## 2. Message Format

### 2.1 Base Message Structure

All messages are JSON objects with the following schema:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "version": "1.0",
  "type": "clipboard|control",
  "payload": { ... }
}
```

#### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | UUID v4 | Yes | Unique message identifier |
| `timestamp` | ISO 8601 | Yes | Message creation time (UTC) |
| `version` | String | Yes | Protocol version (semver) |
| `type` | Enum | Yes | Message type: `clipboard`, `control` |
| `payload` | Object | Yes | Type-specific payload data |

### 2.2 JSON Schema Reference

A machine-readable JSON Schema for protocol messages is available in
[`docs/protocol.schema.json`](./protocol.schema.json). The schema codifies all
required fields, enumerations, and content-specific constraints so clients and
test suites can validate payloads automatically. Example validation command:

```bash
pnpm jsonschema docs/protocol.schema.json payload.json
```

Any linting tool that supports JSON Schema Draft 2020-12 will work.

---

## 3. Clipboard Messages

### 3.1 Clipboard Update Message

Sent when clipboard content changes and needs to be synced.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "version": "1.0",
  "type": "clipboard",
  "payload": {
    "content_type": "text",
    "ciphertext": "BASE64_ENCRYPTED_BYTES",
    "metadata": {
      "size": 13,
      "hash": "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
    },
    "device": {
      "id": "macos-macbook-pro-2025",
      "platform": "macos",
      "name": "Derek's MacBook Pro"
    },
    "encryption": {
      "algorithm": "AES-256-GCM",
      "nonce": "YWJjZGVmZ2hpams=",
      "tag": "bm9uY2VfdGFnX2V4YW1wbGU="
    }
  }
}
```

#### Payload Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content_type` | Enum | Yes | One of: `text`, `link`, `image`, `file` |
| `ciphertext` | String | Yes | Base64-encoded AES-256-GCM payload |
| `device` | Object | Yes | Source device information |
| `target` | String | No | Destination device ID (if routing to a specific peer) |
| `encryption` | Object | Yes | Encryption metadata |

> The `ciphertext` decrypts to a JSON document containing the clipboard bytes and any type-specific metadata (e.g. hashes, filenames, thumbnails).

---

### 3.2 Content Types

#### 3.2.1 Text Content

```json
{
  "content_type": "text",
  "data": "Plain text content here",
  "metadata": {
    "size": 23,
    "hash": "sha256_hash",
    "encoding": "UTF-8"
  }
}
```

**Constraints**:
- Max size: 100KB
- Encoding: UTF-8
- No base64 encoding (sent as plain string)

---

#### 3.2.2 Link Content

```json
{
  "content_type": "link",
  "data": "https://example.com/page",
  "metadata": {
    "size": 25,
    "hash": "sha256_hash",
    "title": "Example Page",
    "favicon": "data:image/png;base64,..."
  }
}
```

**Constraints**:
- Max size: 2KB
- Must be valid URL (RFC 3986)
- Favicon optional, Base64-encoded PNG

---

#### 3.2.3 Image Content

```json
{
  "content_type": "image",
  "data": "iVBORw0KGgoAAAANSUhEUgAAAAUA...",
  "metadata": {
    "size": 45678,
    "hash": "sha256_hash",
    "mime_type": "image/png",
    "width": 1920,
    "height": 1080,
    "format": "png"
  }
}
```

**Constraints**:
- Max size: 10MB (raw image bytes)
- Supported formats: PNG, JPEG, HEIC, HEIF, GIF, WebP, BMP, TIFF
- Base64-encoded in payload
- Auto-compress if >7.5MB:
  - Scale down if longest side >2560px
  - Re-encode as JPEG with quality 85%
  - Progressive quality reduction (75% → 40%) if still too large
  - Target: ~7.5MB raw to stay under 10MB after base64 + JSON overhead

---

#### 3.2.4 File Content

```json
{
  "content_type": "file",
  "data": "UEsDBBQAAAAIALZ...",
  "metadata": {
    "size": 512000,
    "hash": "sha256_hash",
    "filename": "document.pdf",
    "mime_type": "application/pdf",
    "extension": "pdf"
  }
}
```

**Constraints**:
- Max size: 10MB (raw file bytes)
- Base64-encoded in payload
- Preserve original filename
- **macOS storage optimization**: For files that originate on macOS, only a file URL pointer + metadata is stored in history (no duplicate Base64 blob). Bytes are loaded on-demand when:
  - Syncing to other devices
  - Previewing file content
  - Copying to clipboard
  - Opening in Finder
- **Remote files**: Files received from other devices are stored as Base64 so they remain available even if the sender goes offline

---

### 3.3 Metadata Object

The `metadata` object can contain type-specific fields:

| Field | Type | Content Types | Description |
|-------|------|---------------|-------------|
| `size` | Integer | All | Byte size of original content |
| `hash` | String | All | SHA-256 hash of content (hex) |
| `encoding` | String | text | Character encoding (default: UTF-8) |
| `mime_type` | String | image, file | MIME type |
| `filename` | String | file | Original filename with extension |
| `width` | Integer | image | Image width in pixels |
| `height` | Integer | image | Image height in pixels |
| `title` | String | link | Page title (optional) |
| `favicon` | String | link | Base64 favicon (optional) |

---

### 3.4 Device Object

```json
{
  "id": "unique-device-identifier",
  "platform": "macos",
  "name": "User's Device Name",
  "version": "1.0.0"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique device identifier (persisted) |
| `platform` | Enum | `macos`, `android`, `ios`, `windows`, `linux` |
| `name` | String | User-friendly device name |
| `version` | String | App version (semver) |

---

### 3.5 Encryption Object

```json
{
  "algorithm": "AES-256-GCM",
  "nonce": "base64_nonce",
  "tag": "base64_auth_tag"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `algorithm` | String | Always `AES-256-GCM` in v1 |
| `nonce` | String | Base64-encoded 12-byte nonce |
| `tag` | String | Base64-encoded 16-byte authentication tag |

**Note**: The `data` field in the payload is the encrypted ciphertext. Recipients must:
1. Decode Base64 nonce and tag
2. Decrypt `data` using shared key, nonce, and associated data (device ID)
3. Verify authentication tag
4. Decompress the decrypted plaintext (gzip compression is always enabled)

---

### 3.6 Compression

**Status**: ✅ Always enabled (no backward compatibility, no threshold check)

All `ClipboardPayload` JSON payloads are compressed using gzip before encryption. The compression happens at the transport layer:

1. **Encoding**: `ClipboardPayload` is JSON-encoded
2. **Compression**: JSON bytes are gzip-compressed
3. **Encryption**: Compressed bytes are encrypted with AES-256-GCM
4. **Transport**: Encrypted ciphertext is base64-encoded and sent via WebSocket

**Decompression**:
- Recipients must decompress the decrypted plaintext before JSON parsing
- Compression is always applied (no flag checking needed)
- If decompression fails, the payload is treated as uncompressed (for backward compatibility during transition)

**Compression Benefits**:
- **Text content**: 70-90% size reduction
- **JSON structure**: Significant compression of metadata and structure
- **Images**: Minimal impact (3-5% reduction) as images are already compressed
- **Files**: Minimal impact (3-5% reduction) depending on file type

**Implementation**:
- **macOS**: Uses `Compression` framework (zlib algorithm)
- **Android**: Uses `java.util.zip.GZIPInputStream/GZIPOutputStream`

**ClipboardPayload Structure**:
```json
{
  "content_type": "text|link|image|file",
  "data_base64": "base64_encoded_content",
  "metadata": { ... },
  "compressed": true
}
```

The `compressed` field indicates if the JSON payload was compressed (always `true` in current implementation).

---

## 4. Control Messages

### 4.1 Handshake

Sent by client after WebSocket connection established.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "handshake",
    "device": {
      "id": "macos-macbook-pro-2025",
      "platform": "macos",
      "name": "Derek's MacBook Pro",
      "version": "1.0.0"
    },
    "auth": {
      "signature": "base64_signed_challenge"
    }
  }
}
```

**Server Response**:
```json
{
  "id": "...",
  "timestamp": "...",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "handshake_ack",
    "session_id": "unique-session-token",
    "expires_at": "2025-10-01T13:34:56.789Z"
  }
}
```

---

### 4.2 Heartbeat

Sent by client every 30 seconds to keep connection alive.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "ping"
  }
}
```

**Server Response**:
```json
{
  "id": "...",
  "timestamp": "...",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "pong"
  }
}
```

---

### 4.3 Disconnect

Sent by client before closing connection gracefully.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "disconnect",
    "reason": "user_logout"
  }
}
```

**Reasons**: `user_logout`, `app_background`, `network_change`, `device_sleep`

---

### 4.4 Error

Sent by server when an error occurs. Errors always carry a machine readable
`code`, a human readable `message`, and optional contextual `details` to aid in
client remediation.

```json
{
  "id": "...",
  "timestamp": "...",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "error",
    "code": "INVALID_MESSAGE",
    "severity": "error",
    "message": "Message validation failed: missing required field 'content_type'",
    "details": {
      "field": "content_type",
      "path": "payload.content_type",
      "retry_after_ms": 0
    }
  }
}
```

**Details Object**

The `details` object is a structured envelope that MAY contain the following
fields. Clients MUST ignore unknown fields so the server can evolve the shape
over time.

| Field | Type | Description |
|-------|------|-------------|
| `field` | String | Logical field name related to the error. |
| `path` | String | JSON pointer-style path that failed validation. |
| `retry_after_ms` | Integer | Milliseconds a client SHOULD wait before retrying. |
| `hint` | String | Human-readable recommendation for recovery. |
| `context` | Object | Opaque server-provided metadata for logging/diagnostics. |

#### 4.4.1 Error Catalogue

| Code | HTTP Mapping | Severity | Description | Client Action |
|------|--------------|----------|-------------|---------------|
| `INVALID_MESSAGE` | 400 | error | Schema validation failed. | Log and drop frame; retry after fix. |
| `UNSUPPORTED_VERSION` | 426 | error | Protocol version unsupported. | Suspend sync; prompt upgrade; retry after update. |
| `UNAUTHORIZED` | 401 | critical | Authentication failure. | Trigger re-auth; if repeated, force re-pair. |
| `RATE_LIMITED` | 429 | warning | Token bucket exhausted. | Exponential backoff; honor `retry_after_ms`. |
| `PAYLOAD_TOO_LARGE` | 413 | warning | Payload exceeds size cap. | Compress or trim; notify user of skip. |
| `DEVICE_NOT_PAIRED` | 403 | critical | Target device not paired. | Start pairing flow or show pairing error UI. |
| `DEVICE_OFFLINE` | 409 | warning | Destination session not connected. | Queue locally and surface offline banner; auto-resend on reconnect. |
| `DUPLICATE_DEVICE_ID` | 409 | error | Multiple devices attempted to register the same ID. | Force re-registration with unique ID; prompt pairing refresh. |
| `SESSION_CONFLICT` | 423 | error | Message routing conflict detected (e.g., stale session token). | Drop conflicting session and re-establish transport. |
| `INTERNAL_ERROR` | 500 | critical | Unexpected server failure. | Retry with exponential backoff; escalate if persistent. |

> ℹ️ **HTTP Mapping** provides guidance for REST-equivalent analytics dashboards.
> WebSocket frames still use the control message format above.

#### 4.4.2 Retry & Telemetry Guidance

- **Retry Budget**: Clients may retry up to three times for `RATE_LIMITED` and
  `PAYLOAD_TOO_LARGE` after resolving the underlying issue. All other error
  codes require human action.
- **Telemetry**: Log the `code` and `details` fields locally and forward
  aggregates to diagnostics (when user opts in) to track error budgets.
- **Backoff**: Use 1s, 5s, 30s exponential backoff for retryable errors. Reset
  timers after successful message delivery.

#### 4.4.3 Control Message Acknowledgements

For recoverable errors (`RATE_LIMITED`, `PAYLOAD_TOO_LARGE`) the backend MAY
attach a `retry_after` value (in milliseconds) inside `details`. Clients SHOULD
respect this hint before retrying to avoid unnecessary load.

---

## 5. Connection Flow

### 5.1 LAN Direct Connection

```
1. Client → mDNS Query: _hypo._tcp.local
2. Client ← mDNS Response: IP + Port
3. Client → Server: WS Upgrade (wss://IP:PORT)
4. Client ← Server: 101 Switching Protocols
5. Client → Server: Handshake message
6. Client ← Server: Handshake ACK
7. [Connected - ready for clipboard sync]
8. Client → Server: Ping (every 30s)
9. Client ← Server: Pong
```

### 5.2 Cloud Relay Connection

```
1. Client → Relay: WS Upgrade (wss://relay.hypo.app/ws)
2. Client ← Relay: 101 Switching Protocols
3. Client → Relay: Handshake with device ID
4. Client ← Relay: Handshake ACK
5. [Connected - relay maps device ID to connection]
6. Sender → Relay: Clipboard message
7. Relay → Recipient: Forward encrypted message
```

---

## 6. De-duplication Strategy

To prevent infinite clipboard ping-pong:

1. Each device maintains two hashes:
   - `last_sent_hash`: SHA-256 of last sent clipboard
   - `last_received_hash`: SHA-256 of last received clipboard

2. Before sending, check:
   ```
   current_hash = SHA256(clipboard_content)
   if (current_hash == last_sent_hash || current_hash == last_received_hash) {
       return; // Skip sending
   }
   ```

3. After sending: `last_sent_hash = current_hash`

4. After receiving: `last_received_hash = received_hash`

---

## 7. Throttling

**Token Bucket Algorithm**:
- Capacity: 3 tokens
- Refill rate: 1 token per 300ms
- Cost per message: 1 token
- Burst: Allow 3 rapid messages, then throttle

**Implementation**:
```
last_send_time = 0
token_count = 3

function can_send():
    now = current_time_ms()
    elapsed = now - last_send_time
    tokens_to_add = floor(elapsed / 300)
    token_count = min(3, token_count + tokens_to_add)
    last_send_time = now
    
    if token_count > 0:
        token_count -= 1
        return true
    return false
```

---

## 8. Version Negotiation

**Backward Compatibility**:
- Clients send `version` in all messages
- Servers support multiple protocol versions
- If version mismatch:
  ```json
  {
    "type": "control",
    "payload": {
      "action": "error",
      "code": "UNSUPPORTED_VERSION",
      "message": "Protocol version 2.0 not supported. Please upgrade to latest app version.",
      "details": {
        "client_version": "2.0",
        "server_versions": ["1.0", "1.1"]
      }
    }
  }
  ```

**Breaking Changes**:
- Increment major version (1.0 → 2.0)
- Maintain dual-version support for 6 months

**Non-Breaking Changes**:
- Increment minor version (1.0 → 1.1)
- Add optional fields only

---

## 9. Security Considerations

### 9.1 Message Authentication

- Include device ID in associated data for AES-GCM
- Server verifies signature in handshake using stored public key
- Reject messages with timestamp >5 minutes old (replay protection)

### 9.2 Encryption Details

**Key Derivation**:
```
shared_secret = ECDH(client_private_key, server_public_key)
encryption_key = HKDF-SHA256(shared_secret, salt="hypo-clipboard-v1", length=32)
```

**Key Rotation During Pairing** (Implemented November 2025):
- Keys are always rotated during pairing requests, even when re-pairing with existing devices
- Both initiator and responder generate new ephemeral Curve25519 key pairs for each pairing attempt
- The responder includes its ephemeral public key in the ACK message
- The initiator re-derives the shared key using ephemeral keys on both sides: `derive(initiator_ephemeral_private, responder_ephemeral_public)`
- This ensures forward secrecy and prevents key reuse attacks
- No key reuse across pairing sessions

**Encryption Process**:
```
nonce = random_bytes(12)
associated_data = device_id + timestamp
ciphertext, tag = AES-256-GCM.encrypt(
    key=encryption_key,
    nonce=nonce,
    plaintext=clipboard_data,
    associated_data=associated_data
)
```

### 9.3 Rate Limiting

Backend relay enforces:
- 100 messages per minute per device
- 1000 messages per hour per device
- Temporary ban (5 minutes) if exceeded

---

## 10. Examples

### 10.1 Complete Text Sync Flow

**Android → macOS**:

```json
// Android sends
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "timestamp": "2025-10-01T12:00:00.000Z",
  "version": "1.0",
  "type": "clipboard",
  "payload": {
    "content_type": "text",
    "data": "SGVsbG8sIG1hY09TIQ==",
    "metadata": {
      "size": 13,
      "hash": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
      "encoding": "UTF-8"
    },
    "device": {
      "id": "android-redmi-note-13",
      "platform": "android",
      "name": "Redmi Note 13",
      "version": "1.0.0"
    },
    "encryption": {
      "algorithm": "AES-256-GCM",
      "nonce": "YWJjZGVmZ2hpams=",
      "tag": "bm9uY2VfdGFnX2V4YW1wbGU="
    }
  }
}

// macOS receives, decrypts, updates NSPasteboard
// macOS does NOT send back (de-duplication prevents loop)
```

---

## 11. Future Extensions (v2.0+)

- **Compression**: Add `compression` field with gzip support
- **Delta Sync**: Send only diffs for large text
- **Rich Text**: Support RTF/HTML with formatting
- **Clipboard History Sync**: Sync entire history across devices
- **Selective Sync**: Filter by app or content type
- **OCR**: Automatic text extraction from images

---

## Appendix A: JSON Schema

See `docs/protocol-schema.json` for formal JSON Schema definition (coming soon).

---

## Appendix B: Test Vectors

See `tests/protocol-test-vectors.json` for encryption/decryption test vectors (coming soon).

---

**Protocol Version**: 1.0.0  
**Document Authors**: Principal Engineering Team  
**Last Updated**: December 2, 2025


---

## 5. Breaking Changes History

### Device-Agnostic Pairing (November 2025) ✅ Implemented

**Summary**: Pairing system refactored to support pairing between any devices (Android↔Android, macOS↔macOS, Android↔macOS, etc.), not just Android↔macOS.

**Changes**:
1. **Field Names**: Replaced platform-specific field names with role-based names
   - `mac_device_id` → `peer_device_id` (QR payload) or `initiator_device_id`/`responder_device_id` (messages)
   - `android_device_id` → `responder_device_id`
   - `mac_pub_key` → `peer_pub_key` or `initiator_pub_key`/`responder_pub_key`

2. **Platform Detection**: Platform now automatically detected from device ID prefixes
   - `macos-{UUID}` for macOS devices
   - `android-{UUID}` for Android devices
   - `ios-{UUID}`, `windows-{UUID}`, `linux-{UUID}` for future platforms

3. **Backward Compatibility**: Dual field support maintained during transition
   - Old field names still accepted but deprecated
   - New code should use role-based names only

**Migration Path**:
- **Clients**: Update to use new field names
- **Backend**: Supports both old and new field names
- **Timeline**: Old field names will be removed in v2.0

**Status**: Fully deployed and operational in production

For detailed migration information, see `/workspace/docs/archive/breaking_changes_pairing.md`

---

**Document Version**: 1.0.0  
**Last Updated**: December 2, 2025  
**Status**: Production
