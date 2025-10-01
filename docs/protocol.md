# Hypo Clipboard Sync Protocol Specification

Version: 1.0.0-draft  
Status: Draft  
Date: October 1, 2025

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
    "data": "Hello, world!",
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
| `data` | String | Yes | Content (Base64 for binary) |
| `metadata` | Object | No | Type-specific metadata |
| `device` | Object | Yes | Source device information |
| `target` | String | No | Destination device ID (if routing to a specific peer) |
| `encryption` | Object | Yes | Encryption metadata |

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
- Max size: 1MB
- Supported formats: PNG, JPEG
- Base64-encoded
- Auto-compress if >1MB

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
- Max size: 1MB
- Base64-encoded
- Preserve original filename

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

Sent by server when an error occurs.

```json
{
  "id": "...",
  "timestamp": "...",
  "version": "1.0",
  "type": "control",
  "payload": {
    "action": "error",
    "code": "INVALID_MESSAGE",
    "message": "Message validation failed: missing required field 'content_type'",
    "details": {
      "field": "content_type"
    }
  }
}
```

**Error Codes**:
- `INVALID_MESSAGE`: Malformed JSON or missing fields
- `UNSUPPORTED_VERSION`: Protocol version mismatch
- `UNAUTHORIZED`: Authentication failed
- `RATE_LIMITED`: Too many requests
- `PAYLOAD_TOO_LARGE`: Content exceeds size limit
- `DEVICE_NOT_PAIRED`: Devices not paired

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

**Protocol Version**: 1.0.0-draft  
**Document Authors**: Principal Engineering Team  
**Last Updated**: October 1, 2025

