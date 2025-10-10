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
- Nonces generated per message; tamper detection verified through authentication tag checks on both platforms.
- Shared secrets persisted in macOS keychain / Android EncryptedSharedPreferences through injected storage closures.

### 4. Relay API Protections
- API returns 410 Gone when polling expired codes; clients surface actionable error copy.
- Relay denies challenge/ack polling for mismatched device IDs, preventing hijacked sessions.
- Rate limiting active on pairing endpoints to mitigate brute force attempts.

### 5. Logging & Telemetry
- Sensitive payloads (public keys, ciphertext) excluded from structured logs; only high-level event metadata recorded.
- Recommendation: add security-focused metrics (failed claim counts, tamper detections) to monitoring dashboard. _Status: Filed follow-up._

## Conclusion
Phase 6.2 remote pairing flow meets baseline security requirements for beta. Two medium-priority hardening tasks were identified and queued for Sprint 7 monitoring work.
