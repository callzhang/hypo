/// AES-256-GCM interoperability vectors derived from RFC 5116 test cases.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AeadTestVector {
    pub name: &'static str,
    pub key: [u8; 32],
    pub nonce: [u8; 12],
    pub aad: Vec<u8>,
    pub plaintext: Vec<u8>,
    pub ciphertext: Vec<u8>,
}

pub fn aes_256_gcm_vectors() -> Vec<AeadTestVector> {
    vec![
        AeadTestVector {
            name: "rfc-5116-case-16",
            key: [0u8; 32],
            nonce: [0u8; 12],
            aad: Vec::new(),
            plaintext: Vec::new(),
            ciphertext: hex::decode("530f8afbc74536b9a963b4f1c4cb738b").unwrap(),
        },
        AeadTestVector {
            name: "rfc-5116-case-17",
            key: [0u8; 32],
            nonce: [0u8; 12],
            aad: Vec::new(),
            plaintext: hex::decode("00000000000000000000000000000000").unwrap(),
            ciphertext: hex::decode(
                "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919",
            )
            .unwrap(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vectors_have_expected_lengths() {
        for vector in aes_256_gcm_vectors() {
            assert_eq!(vector.key.len(), 32);
            assert_eq!(vector.nonce.len(), 12);
        }
    }
}
