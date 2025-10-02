use anyhow::{ensure, Result};
use hkdf::Hkdf;
use rand::rngs::OsRng;
use sha2::Sha256;
use std::convert::TryInto;
use x25519_dalek::{PublicKey, StaticSecret};

const HKDF_SALT: &[u8] = b"hypo-clipboard-ecdh";
const HKDF_INFO: &[u8] = b"hypo-aes-256-gcm";

/// Performs X25519 key agreement and derives a symmetric 256-bit key via HKDF-SHA256.
pub fn derive_symmetric_key(private: &[u8], public: &[u8]) -> Result<[u8; 32]> {
    ensure!(private.len() == 32, "private key must be 32 bytes");
    ensure!(public.len() == 32, "public key must be 32 bytes");

    let private_bytes: [u8; 32] = private
        .try_into()
        .map_err(|_| anyhow::anyhow!("private key must be 32 bytes"))?;
    let public_bytes: [u8; 32] = public
        .try_into()
        .map_err(|_| anyhow::anyhow!("public key must be 32 bytes"))?;

    let private = StaticSecret::from(private_bytes);
    let public = PublicKey::from(public_bytes);

    let shared_secret = private.diffie_hellman(&public);
    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), shared_secret.as_bytes());
    let mut okm = [0u8; 32];
    hk.expand(HKDF_INFO, &mut okm)
        .map_err(|err| anyhow::anyhow!("failed to expand HKDF: {err}"))?;

    Ok(okm)
}

/// Generates a new X25519 keypair backed by the operating system RNG.
pub fn generate_keypair() -> ([u8; 32], [u8; 32]) {
    let private = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&private);
    (private.to_bytes(), public.to_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_keys_are_equal() {
        let (priv_a, pub_a) = generate_keypair();
        let (priv_b, pub_b) = generate_keypair();

        let key_ab = derive_symmetric_key(&priv_a, &pub_b).unwrap();
        let key_ba = derive_symmetric_key(&priv_b, &pub_a).unwrap();

        assert_eq!(key_ab, key_ba);
    }
}
