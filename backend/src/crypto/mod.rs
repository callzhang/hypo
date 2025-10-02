pub mod aead;
pub mod key_agreement;
pub mod test_vectors;

use aead::{decrypt, encrypt, EncryptionResult};
use anyhow::Result;
use key_agreement::derive_symmetric_key;

/// High-level cryptography facade used by the relay to handle
/// authenticated encryption and key agreement operations.
pub struct CryptoService;

impl CryptoService {
    /// Encrypts the provided plaintext with AES-256-GCM using the supplied key.
    ///
    /// The resulting ciphertext contains both the encrypted bytes and the
    /// authentication tag. A freshly generated 96-bit nonce is returned alongside
    /// the ciphertext so callers can transmit it with the payload.
    pub fn encrypt(key: &[u8], plaintext: &[u8], aad: &[u8]) -> Result<EncryptionResult> {
        encrypt(key, plaintext, aad)
    }

    /// Decrypts the provided AES-256-GCM payload using the supplied key and nonce.
    ///
    /// The ciphertext must contain the authentication tag appended to the end of
    /// the encrypted bytes as produced by [`CryptoService::encrypt`].
    pub fn decrypt(
        key: &[u8],
        nonce: &[u8],
        ciphertext: &[u8],
        tag: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>> {
        decrypt(key, nonce, ciphertext, tag, aad)
    }

    /// Performs an X25519 Diffie-Hellman exchange and derives a 256-bit key using HKDF.
    pub fn derive_key(private: &[u8], public: &[u8]) -> Result<[u8; 32]> {
        derive_symmetric_key(private, public)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::key_agreement;
    use crate::crypto::test_vectors::aes_256_gcm_vectors;
    use rand::{rngs::OsRng, RngCore};

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);

        let plaintext = b"hypo clipboard relay";
        let aad = b"device:test";

        let encrypted = CryptoService::encrypt(&key, plaintext, aad).expect("encryption failed");
        let decrypted = CryptoService::decrypt(
            &key,
            &encrypted.nonce,
            &encrypted.ciphertext,
            &encrypted.tag,
            aad,
        )
        .expect("decryption failed");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn matches_known_aes_256_gcm_vector() {
        let vector = aes_256_gcm_vectors()
            .into_iter()
            .find(|v| v.name == "rfc-5116-case-17")
            .expect("expected test vector");

        let encrypted =
            aead::encrypt_with_nonce(&vector.key, &vector.nonce, &vector.plaintext, &vector.aad)
                .expect("vector encryption failed");
        assert_eq!(encrypted, vector.ciphertext);

        let decrypted = CryptoService::decrypt(
            &vector.key,
            &vector.nonce,
            &vector.ciphertext[..vector.ciphertext.len() - 16],
            &vector.ciphertext[vector.ciphertext.len() - 16..],
            &vector.aad,
        )
        .expect("vector decryption failed");
        assert_eq!(decrypted, vector.plaintext);
    }

    #[test]
    fn derive_key_matches_between_participants() {
        let (priv_a, pub_a) = key_agreement::generate_keypair();
        let (priv_b, pub_b) = key_agreement::generate_keypair();

        let key_ab = CryptoService::derive_key(&priv_a, &pub_b).expect("derive key a->b");
        let key_ba = CryptoService::derive_key(&priv_b, &pub_a).expect("derive key b->a");

        assert_eq!(key_ab, key_ba);
    }

    #[test]
    fn derive_key_rejects_invalid_lengths() {
        let result = CryptoService::derive_key(&[1, 2, 3], &[4, 5, 6]);
        assert!(result.is_err());
    }
}
