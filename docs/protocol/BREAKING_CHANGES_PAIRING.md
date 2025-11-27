# Breaking Changes: Device-Agnostic Pairing

## Overview

This document summarizes the breaking changes introduced when removing backward compatibility from the pairing system. **All devices must be re-paired after this update** as the pairing protocol no longer supports legacy field names.

## Date

**2025-01-XX** (To be updated with actual deployment date)

## Impact

- **Severity**: 🔴 **CRITICAL** - All existing pairings will stop working
- **Scope**: All platforms (Android, macOS, iOS, Windows, Linux)
- **Action Required**: Users must re-pair all devices after updating

## Changes Summary

### 1. Pairing Protocol Field Names

#### Removed Fields (No Longer Accepted)

**PairingPayload:**
- `mac_device_id` → Use `peer_device_id` only
- `mac_pub_key` → Use `peer_pub_key` only
- `mac_signing_pub_key` → Use `peer_signing_pub_key` only

**PairingChallengeMessage:**
- `android_device_id` → Use `initiator_device_id` only
- `android_device_name` → Use `initiator_device_name` only
- `android_pub_key` → Use `initiator_pub_key` only

**PairingAckMessage:**
- `mac_device_id` → Use `responder_device_id` only
- `mac_device_name` → Use `responder_device_name` only

#### New Field Names (Required)

All pairing messages now use role-based naming:

- **Initiator** (device that starts pairing): `initiator_device_id`, `initiator_device_name`, `initiator_pub_key`
- **Responder** (device that responds): `responder_device_id`, `responder_device_name`
- **Peer** (generic peer in QR payload): `peer_device_id`, `peer_pub_key`, `peer_signing_pub_key`

### 2. Backend API Changes

#### Removed Query Parameters

**Challenge Polling:**
- `mac_device_id` → Use `initiator_device_id` only

**ACK Polling:**
- `android_device_id` → Use `responder_device_id` only

#### Removed Request Body Fields

**Create Pairing Code:**
- `mac_device_id`, `mac_device_name`, `mac_public_key` → Use `initiator_*` fields only

**Claim Pairing Code:**
- `android_device_id`, `android_device_name`, `android_public_key` → Use `responder_*` fields only

**Submit Challenge:**
- `android_device_id` → Use `responder_device_id` only

**Submit ACK:**
- `mac_device_id` → Use `initiator_device_id` only

### 3. Message Detection Changes

#### WebSocket Message Detection

**macOS (`LanWebSocketServer`):**
- No longer checks for `android_device_id` or `android_pub_key` in pairing messages
- Only accepts `initiator_device_id` and `initiator_pub_key`

**Android (`LanWebSocketClient`):**
- No longer checks for `mac_device_id` in ACK messages
- Only accepts `responder_device_id`

### 4. Data Model Changes

#### Android Models

**Removed Properties:**
- `PairingPayload.macDeviceId`, `macPublicKey`, `macSigningPublicKey`
- `PairingPayload.deviceId`, `publicKey`, `signingPublicKey` (helper properties)
- `PairingChallengeMessage.androidDeviceId`, `androidDeviceName`, `androidPublicKey`
- `PairingChallengeMessage.deviceId`, `deviceName`, `publicKey` (helper properties)
- `PairingAckMessage.macDeviceId`, `macDeviceName`
- `PairingAckMessage.deviceId`, `deviceName` (helper properties)

**Direct Access Required:**
- Use `payload.peerDeviceId` instead of `payload.deviceId`
- Use `payload.peerPublicKey` instead of `payload.publicKey`
- Use `challenge.initiatorDeviceId` instead of `challenge.deviceId`
- Use `ack.responderDeviceId` instead of `ack.deviceId`

#### Swift Models

**Removed CodingKeys:**
- `macDeviceId`, `macPublicKey`, `macSigningPublicKey` from `PairingPayload`
- `androidDeviceId`, `androidDeviceName`, `androidPublicKey` from `PairingChallengeMessage`
- `macDeviceId`, `macDeviceName` from `PairingAckMessage`

**Simplified Decoders:**
- Custom decoders no longer attempt to decode old field names
- Decoding will fail if old field names are present

#### Rust Backend

**Removed Serde Aliases:**
- `#[serde(alias = "mac_device_id")]` removed from all structs
- `#[serde(alias = "android_device_id")]` removed from all structs
- All related aliases removed from `PairingCodeEntry` and request/response structs

### 5. QR Code Payload Changes

**Android (`LanPairingViewModel.createQrPayloadFromDevice`):**
- No longer includes `mac_device_id`, `mac_pub_key`, `mac_signing_pub_key` in QR payload
- Only includes `peer_device_id`, `peer_pub_key`, `peer_signing_pub_key`

### 6. Signature Encoding Changes

**Android (`PairingHandshakeManager.encodeWithSortedKeys`):**
- No longer includes backward compatibility fields in signature calculation
- Only includes new field names in sorted key encoding

## Migration Path

### For Users

1. **Update all devices** to the new version
2. **Delete all existing pairings** (or they will be automatically invalidated)
3. **Re-pair all devices** using either:
   - LAN discovery (Bonjour/mDNS)
   - Cloud pairing with generated codes

### For Developers

1. **Remove all references** to old field names in code
2. **Update tests** to use new field names only
3. **Update documentation** to reflect new field names
4. **Test pairing flows** end-to-end after migration

## Testing Checklist

- [ ] Android → Android LAN pairing
- [ ] Android → macOS LAN pairing
- [ ] macOS → Android LAN pairing
- [ ] Android → Android cloud pairing
- [ ] Android → macOS cloud pairing
- [ ] macOS → Android cloud pairing
- [ ] Verify old field names are rejected
- [ ] Verify signature verification works with new fields only
- [ ] Verify device exclusion (self and already-paired) works

## Rollback Plan

If issues are discovered:

1. **DO NOT** rollback to old field names - this would break new clients
2. **Fix issues** in the new implementation
3. **Re-deploy** with fixes
4. **Users must re-pair** again (this is expected and acceptable)

## Notes

- Platform-prefixed device IDs (e.g., `macos-{UUID}`, `android-{UUID}`) are still supported during decoding for migration purposes, but should not be used in new pairings
- The `migrateDeviceId` function still strips platform prefixes to ensure clean UUID storage
- Device ID format migration is separate from field name changes

## Related Files

### Modified Files

**Android:**
- `android/app/src/main/java/com/hypo/clipboard/pairing/PairingModels.kt`
- `android/app/src/main/java/com/hypo/clipboard/pairing/PairingHandshakeManager.kt`
- `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`
- `android/app/src/main/java/com/hypo/clipboard/pairing/RemotePairingViewModel.kt`
- `android/app/src/main/java/com/hypo/clipboard/pairing/PairingRelayClient.kt`
- `android/app/src/main/java/com/hypo/clipboard/transport/ws/LanWebSocketClient.kt`

**macOS:**
- `macos/Sources/HypoApp/Pairing/PairingModels.swift`
- `macos/Sources/HypoApp/Services/PairingRelayClient.swift`
- `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`

**Backend:**
- `backend/src/services/redis_client.rs`
- `backend/src/handlers/pairing.rs`

## Questions?

If you have questions about these breaking changes, please:
1. Review the code changes in the related files
2. Check the pairing protocol documentation
3. Test the pairing flows in a development environment

