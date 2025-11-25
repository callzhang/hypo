# Remote Pairing Security Audit

_Date:_ October 10, 2025  
_Auditor:_ Hypo Engineering

## Scope
- Remote relay pairing workflow between macOS and Android clients (Phase 6.2).
- Backend relay endpoints responsible for pairing code lifecycle.
- Cryptographic material exchange and storage on both clients.

## Findings
### 1. Pairing Code Issuance
- Codes are generated server-side with 6-digit entropy and a 60-second TTL in Redis.
- Backend enforces uniqueness and ownership by namespace (mac device ID) before storing.
- Recommendation: increase entropy to 8 digits to harden against brute force in future release. _Status: Backlog ticket filed._

### 2. Challenge Transport & Validation
- macOS signs QR payloads with Curve25519 before display; remote workflow reuses the same key material.
- Android validates QR signature and the relay-supplied mac public key before deriving the shared secret.
- Challenge payloads include ISO8601 timestamps; macOS enforces configurable tolerance (default 30s) when decrypting.

### 3. Cryptography
- ECDH performed with Curve25519 key agreement; derived symmetric key is AES-256-GCM via HKDF-SHA256.
- **Key Rotation on Pairing**: Keys are always rotated during pairing requests. Both initiator (Android) and responder (macOS) generate new ephemeral key pairs for each pairing attempt. The responder includes its ephemeral public key in the ACK message, allowing the initiator to re-derive the shared key using ephemeral keys on both sides. This ensures forward secrecy and prevents key reuse attacks, even when re-pairing with existing devices.
- Nonces generated per message; tamper detection verified through authentication tag checks on both platforms.
- Shared secrets persisted in macOS keychain / Android EncryptedSharedPreferences through injected storage closures.

#### 3.1 Key Rotation During Pairing - Detailed Process

**Overview**: Every pairing request (including re-pairing with existing devices) generates a new shared encryption key using ephemeral key pairs on both sides. This provides forward secrecy and prevents key reuse attacks.

**Detailed Flow**:

1. **Initial Challenge Encryption (Temporary Shared Key)**:
   - Android (initiator) generates a new ephemeral Curve25519 private key: `android_ephemeral_priv_1`
   - Android derives initial shared key using macOS's persistent public key (from Bonjour): 
     ```
     initial_shared_key = ECDH(android_ephemeral_priv_1, macos_persistent_pub)
     ```
   - Android encrypts challenge using `initial_shared_key` and sends it to macOS

2. **Challenge Decryption (macOS)**:
   - macOS uses its persistent private key to derive the same initial shared key:
     ```
     initial_shared_key = ECDH(macos_persistent_priv, android_ephemeral_pub_1)
     ```
   - macOS decrypts the challenge using `initial_shared_key`

3. **Key Rotation (Ephemeral Key Exchange)**:
   - macOS generates a new ephemeral Curve25519 private key: `macos_ephemeral_priv_2`
   - macOS includes its ephemeral public key in the ACK payload: `macos_ephemeral_pub_2`
   - ACK is encrypted with `initial_shared_key` (for backward compatibility)

4. **Final Shared Key Derivation (Android)**:
   - Android receives ACK and extracts `macos_ephemeral_pub_2`
   - Android re-derives the final shared key using ephemeral keys on both sides:
     ```
     final_shared_key = ECDH(android_ephemeral_priv_1, macos_ephemeral_pub_2)
     ```
   - This final key is stored for future message encryption/decryption

5. **Key Storage**:
   - Android stores `final_shared_key` under macOS's device ID
   - macOS stores `final_shared_key` under Android's device ID
   - Both devices use the same key value (symmetric encryption)

**Example**:

```
Pairing Session #1 (First Time):
─────────────────────────────────
Android generates: ephemeral_priv_A1 → ephemeral_pub_A1
macOS generates:   ephemeral_priv_M1 → ephemeral_pub_M1

Initial shared key (for challenge):
  Android: ECDH(ephemeral_priv_A1, macos_persistent_pub)
  macOS:   ECDH(macos_persistent_priv, ephemeral_pub_A1)
  → initial_key_1

Final shared key (stored):
  Android: ECDH(ephemeral_priv_A1, ephemeral_pub_M1) → stored_key_1
  macOS:   ECDH(ephemeral_priv_M1, ephemeral_pub_A1) → stored_key_1
  ✅ Both derive the same key (ECDH property)


Pairing Session #2 (Re-pairing):
─────────────────────────────────
Android generates: ephemeral_priv_A2 → ephemeral_pub_A2  (NEW!)
macOS generates:   ephemeral_priv_M2 → ephemeral_pub_M2  (NEW!)

Initial shared key (for challenge):
  Android: ECDH(ephemeral_priv_A2, macos_persistent_pub)
  macOS:   ECDH(macos_persistent_priv, ephemeral_pub_A2)
  → initial_key_2  (different from initial_key_1)

Final shared key (stored):
  Android: ECDH(ephemeral_priv_A2, ephemeral_pub_M2) → stored_key_2
  macOS:   ECDH(ephemeral_priv_M2, ephemeral_pub_A2) → stored_key_2
  ✅ New key (different from stored_key_1) - KEY ROTATED!
```

**Security Properties**:
- ✅ **Forward Secrecy**: Even if a key is compromised, previous messages remain secure (new key each pairing)
- ✅ **Key Reuse Prevention**: Re-pairing generates a completely new key, preventing reuse attacks
- ✅ **Ephemeral Keys**: Both sides use temporary keys that are discarded after key derivation
- ✅ **Backward Compatibility**: If ephemeral public key is missing from ACK, Android falls back to initial shared key

**Implementation Notes**:
- The persistent key is only used for initial challenge encryption/decryption
- The final shared key is always derived from ephemeral keys on both sides
- Ephemeral keys are generated fresh for each pairing attempt
- No key material is reused across pairing sessions

### 4. Relay API Protections
- API returns 410 Gone when polling expired codes; clients surface actionable error copy.
- Relay denies challenge/ack polling for mismatched device IDs, preventing hijacked sessions.
- Rate limiting active on pairing endpoints to mitigate brute force attempts.

### 5. Logging & Telemetry
- Sensitive payloads (public keys, ciphertext) excluded from structured logs; only high-level event metadata recorded.
- Recommendation: add security-focused metrics (failed claim counts, tamper detections) to monitoring dashboard. _Status: Filed follow-up._

## Conclusion
Phase 6.2 remote pairing flow meets baseline security requirements for beta. Two medium-priority hardening tasks were identified and queued for Sprint 7 monitoring work.
