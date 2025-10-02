package com.hypo.clipboard.crypto

import com.google.crypto.tink.subtle.Hkdf
import com.google.crypto.tink.subtle.X25519
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val KEY_LENGTH_BYTES = 32
private const val NONCE_LENGTH_BYTES = 12
private const val TAG_LENGTH_BYTES = 16
private const val GCM_TAG_LENGTH_BITS = TAG_LENGTH_BYTES * 8
private val HKDF_SALT = "hypo-clipboard-ecdh".toByteArray()
private val HKDF_INFO = "hypo-aes-256-gcm".toByteArray()

class CryptoService @Inject constructor(
    private val nonceGenerator: NonceGenerator = SecureRandomNonceGenerator()
) {

    suspend fun encrypt(
        plaintext: ByteArray,
        key: ByteArray,
        aad: ByteArray? = null
    ): EncryptedData = withContext(Dispatchers.Default) {
        require(key.size == KEY_LENGTH_BYTES) { "key must be 32 bytes" }

        val nonce = nonceGenerator.generate(NONCE_LENGTH_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val keySpec = SecretKeySpec(key, "AES")
        val gcmSpec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, nonce)
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, gcmSpec)
        aad?.takeIf { it.isNotEmpty() }?.let(cipher::updateAAD)
        val encrypted = cipher.doFinal(plaintext)
        val tag = encrypted.copyOfRange(encrypted.size - TAG_LENGTH_BYTES, encrypted.size)
        val ciphertext = encrypted.copyOfRange(0, encrypted.size - TAG_LENGTH_BYTES)
        EncryptedData(ciphertext = ciphertext, nonce = nonce, tag = tag)
    }

    suspend fun decrypt(
        encrypted: EncryptedData,
        key: ByteArray,
        aad: ByteArray? = null
    ): ByteArray = withContext(Dispatchers.Default) {
        require(key.size == KEY_LENGTH_BYTES) { "key must be 32 bytes" }
        require(encrypted.nonce.size == NONCE_LENGTH_BYTES) { "nonce must be 12 bytes" }
        require(encrypted.tag.size == TAG_LENGTH_BYTES) { "tag must be 16 bytes" }

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val keySpec = SecretKeySpec(key, "AES")
        val gcmSpec = GCMParameterSpec(GCM_TAG_LENGTH_BITS, encrypted.nonce)
        cipher.init(Cipher.DECRYPT_MODE, keySpec, gcmSpec)
        aad?.takeIf { it.isNotEmpty() }?.let(cipher::updateAAD)
        val combined = encrypted.ciphertext + encrypted.tag
        cipher.doFinal(combined)
    }

    suspend fun deriveKey(privateKey: ByteArray, publicKey: ByteArray): ByteArray =
        withContext(Dispatchers.Default) {
            if (privateKey.size != KEY_LENGTH_BYTES || publicKey.size != KEY_LENGTH_BYTES) {
                throw GeneralSecurityException("key material must be 32 bytes")
            }
            val shared = X25519.computeSharedSecret(privateKey, publicKey)
            Hkdf.computeHkdf("HmacSha256", shared, HKDF_SALT, HKDF_INFO, KEY_LENGTH_BYTES)
        }

}

fun interface NonceGenerator {
    fun generate(length: Int): ByteArray
}

class SecureRandomNonceGenerator @Inject constructor() : NonceGenerator {
    private val random = java.security.SecureRandom()

    override fun generate(length: Int): ByteArray = ByteArray(length).also(random::nextBytes)
}

data class EncryptedData(
    val ciphertext: ByteArray,
    val nonce: ByteArray,
    val tag: ByteArray
)
