use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{ensure, Result};

/// Result of encrypting a payload using AES-256-GCM.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncryptionResult {
    pub nonce: [u8; 12],
    pub ciphertext: Vec<u8>,
}

/// Encrypts the provided plaintext with AES-256-GCM using a randomly generated nonce.
pub fn encrypt(key: &[u8], plaintext: &[u8], aad: &[u8]) -> Result<EncryptionResult> {
    ensure!(key.len() == 32, "AES-256-GCM requires a 32-byte key");

    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|err| anyhow::anyhow!("invalid key provided: {err}"))?;
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);

    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|err| anyhow::anyhow!("encryption failed: {err}"))?;

    let mut nonce_bytes = [0u8; 12];
    nonce_bytes.copy_from_slice(&nonce);

    Ok(EncryptionResult {
        nonce: nonce_bytes,
        ciphertext,
    })
}

/// Decrypts an AES-256-GCM payload using the provided key and nonce.
pub fn decrypt(key: &[u8], nonce: &[u8], ciphertext: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    ensure!(key.len() == 32, "AES-256-GCM requires a 32-byte key");
    ensure!(nonce.len() == 12, "AES-256-GCM requires a 12-byte nonce");

    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|err| anyhow::anyhow!("invalid key provided: {err}"))?;
    let nonce = Nonce::from_slice(nonce);

    cipher
        .decrypt(
            nonce,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("decryption failed"))
}

/// Deterministic encryption helper exposed for tests to validate known vectors.
#[cfg(test)]
pub fn encrypt_with_nonce(
    key: &[u8],
    nonce: &[u8; 12],
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>> {
    ensure!(key.len() == 32, "AES-256-GCM requires a 32-byte key");

    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|err| anyhow::anyhow!("invalid key provided: {err}"))?;
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|err| anyhow::anyhow!("encryption failed: {err}"))?;

    Ok(ciphertext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_rejects_short_keys() {
        let result = encrypt(b"short", b"data", b"");
        assert!(result.is_err());
    }

    #[test]
    fn decrypt_rejects_short_nonce() {
        let key = [0u8; 32];
        let result = decrypt(&key, b"bad", b"", b"");
        assert!(result.is_err());
    }
}
