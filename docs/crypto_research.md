# Cryptography Library Evaluation

**Last Updated:** October 3, 2025  
**Author:** Hypo Engineering

## Requirements Snapshot

- AES-256-GCM for authenticated clipboard payload encryption
- ECDH (Curve25519) for key agreement during pairing
- Secure random nonce generation with monotonic guarantees per session
- Cross-platform portability across macOS (Swift), Android (Kotlin/Java), and Rust backend
- FIPS 140-3 readiness for potential enterprise distribution
- Active maintenance and permissive licensing

## Summary

| Platform | Candidate | Status | Strengths | Gaps / Considerations | Recommendation |
|----------|-----------|--------|-----------|-----------------------|----------------|
| macOS | [CryptoKit](https://developer.apple.com/documentation/cryptokit) | ✅ Preferred | First-party, hardware-backed keys, tight Swift integration, automatic nonce management helpers. | Requires macOS 10.15+ (met), needs manual key persistence strategy. | Adopt for production. Prototype AES-GCM wrappers in Sprint 2. |
| Android | [Google Tink](https://github.com/google/tink) | ✅ Preferred | Opinionated AEAD APIs, built-in key versioning, wide documentation, works with Jetpack Security. | Binary size impact (~1.2MB), requires shaded artifacts for min SDK 26. | Adopt for production with Kotlin multiplatform wrapper. |
| Backend | [RustCrypto AEAD (`aes-gcm`)](https://github.com/RustCrypto/AEADs/tree/master/aes-gcm) | ✅ Preferred | Pure Rust, audited, works with `rand` + `hkdf` crates, interoperable with clients. | Ensure constant-time builds (`aes` crate) and enable `aes` hardware acceleration. | Adopt; pair with `x25519-dalek` + `hkdf`. |

## macOS Findings

- **CryptoKit Coverage**: Provides `AES.GCM.SealedBox` for envelope encryption with authenticated data. Supports symmetric keys derived from `Curve25519.KeyAgreement`.  
- **Key Storage**: We'll store symmetric keys in the user's Keychain using `SecKey` for persistence and wrap them with CryptoKit when decrypting.  
- **Nonce Strategy**: Use CryptoKit's `AES.GCM.Nonce()` for random nonces per message; include sender session counter in associated data to detect replays.  
- **Action Item**: Implement thin wrappers in `HypoCrypto` module during Sprint 2.

## Android Findings

- **Tink Primitives**: `AeadConfig.register()` + `AeadFactory.getPrimitive()` supply AES-256-GCM via `AesGcmKeyManager`.  
- **Key Management**: Combine with `MasterKey` from Jetpack Security for on-device persistence, fallback to manual key storage for HyperOS devices lacking Google Play Services.  
- **Nonce Strategy**: Tink handles nonce creation internally; we only need to ensure message counters are part of associated data.  
- **Action Item**: Add Gradle dependency `com.google.crypto.tink:tink-android:1.13.0` and wrap with coroutine-friendly helper.

## Backend Findings

- **RustCrypto Stack**: Use `aes-gcm` crate with `heapless` buffer for low allocation overhead.  
- **Key Agreement**: Pair with `x25519-dalek` for ECDH, derive symmetric key through `hkdf::Hkdf::<Sha256>`.  
- **Nonce Strategy**: Generate 96-bit random nonces using `rand_core::OsRng`; store last nonce per session to detect duplicates.  
- **Action Item**: Create `crypto` module in backend with integration tests verifying interoperability against fixtures from clients.

## Next Steps

1. Draft cross-platform encryption spec (nonce layout, associated data) – owner: Backend (Sprint 2, Week 1).
2. Add dependency stubs to `Package.swift`, `build.gradle`, and `Cargo.toml` with feature flags disabled until implementation.  
3. Prototype encryption round-trip tests using common test vectors.

## Risks

- **Binary Size on Android**: Monitor release APK size increase; consider ProGuard/R8 rules.  
- **Hardware Acceleration Variance**: Some Android devices may lack AES-NI equivalents; measure performance during beta.  
- **Regulatory**: If enterprise customers require FIPS validation, may need alternative providers; keep abstraction boundary clean.
