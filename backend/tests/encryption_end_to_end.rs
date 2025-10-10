use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use hypo_relay::crypto::{aead, key_agreement};

#[test]
fn symmetric_key_exchange_and_encryption_roundtrip() {
    let (priv_a, pub_a) = key_agreement::generate_keypair();
    let (priv_b, pub_b) = key_agreement::generate_keypair();

    let key_a = key_agreement::derive_symmetric_key(&priv_a, &pub_b).expect("key A derivation");
    let key_b = key_agreement::derive_symmetric_key(&priv_b, &pub_a).expect("key B derivation");

    assert_eq!(key_a, key_b, "derived keys must match");

    let plaintext = b"clipboard payload";
    let aad = b"{\"type\":\"clipboard\"}";

    let encrypted = aead::encrypt(&key_a, plaintext, aad).expect("encrypt");
    let decrypted = aead::decrypt(&key_b, &encrypted.nonce, &encrypted.ciphertext, &encrypted.tag, aad)
        .expect("decrypt");

    assert_eq!(decrypted, plaintext);

    // Ensure payloads are safe for transport by checking Base64 encoding outputs
    let encoded_nonce = BASE64.encode(encrypted.nonce);
    let encoded_tag = BASE64.encode(encrypted.tag);
    let encoded_cipher = BASE64.encode(&encrypted.ciphertext);

    assert_eq!(BASE64.decode(encoded_nonce.as_bytes()).unwrap(), encrypted.nonce);
    assert_eq!(BASE64.decode(encoded_tag.as_bytes()).unwrap(), encrypted.tag);
    assert_eq!(BASE64.decode(encoded_cipher.as_bytes()).unwrap(), encrypted.ciphertext);
}

#[test]
fn tampering_detected_during_decryption() {
    let (priv_a, _pub_a) = key_agreement::generate_keypair();
    let (_priv_b, pub_b) = key_agreement::generate_keypair();

    let key = key_agreement::derive_symmetric_key(&priv_a, &pub_b).expect("key derivation");
    let aad = b"{\"type\":\"clipboard\"}";
    let mut encrypted = aead::encrypt(&key, b"message", aad).expect("encrypt");

    // Flip a bit in the ciphertext to ensure authentication fails.
    if let Some(first_byte) = encrypted.ciphertext.get_mut(0) {
        *first_byte ^= 0b0000_0001;
    }

    let result = aead::decrypt(&key, &encrypted.nonce, &encrypted.ciphertext, &encrypted.tag, aad);
    assert!(result.is_err(), "tampering should be detected");
}
