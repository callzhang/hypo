package com.hypo.clipboard.crypto

import java.nio.file.Files
import java.nio.file.Path
import java.security.GeneralSecurityException
import java.util.Base64
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CryptoServiceTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun encryptDecryptRoundTrip() = runTest {
        val nonce = ByteArray(12) { 0xAB.toByte() }
        val service = CryptoService { nonce }
        val key = ByteArray(32) { index -> index.toByte() }
        val plaintext = "hello-hypo".encodeToByteArray()
        val aad = "device-123".encodeToByteArray()

        val encrypted = service.encrypt(plaintext, key, aad)
        assertContentEquals(nonce, encrypted.nonce)

        val decrypted = service.decrypt(encrypted, key, aad)
        assertContentEquals(plaintext, decrypted)
    }

    @Test
    fun decryptMatchesRustVector() = runTest {
        val vectors = loadVectors()
        val vector = requireNotNull(vectors.testCases.firstOrNull())
        val service = CryptoService { vector.nonce }
        val encrypted = EncryptedData(
            ciphertext = vector.ciphertext,
            nonce = vector.nonce,
            tag = vector.tag
        )
        val plaintext = service.decrypt(encrypted, vector.key, vector.aad)
        assertContentEquals(vector.plaintext, plaintext)
    }

    @Test
    fun deriveKeyMatchesBackendVector() = runTest {
        val vectors = loadVectors()
        val service = CryptoService()
        val derived = service.deriveKey(
            vectors.keyAgreement.alicePrivate,
            vectors.keyAgreement.bobPublic
        )
        assertContentEquals(vectors.keyAgreement.sharedKey, derived)
    }

    @Test
    fun deriveKeyRejectsInvalidLength() = runTest {
        val service = CryptoService()
        assertFailsWith<GeneralSecurityException> {
            service.deriveKey(byteArrayOf(1, 2, 3), byteArrayOf(4, 5, 6))
        }
    }

    private fun loadVectors(): CryptoVectors {
        val path = locateRepositoryRoot().resolve("tests/crypto_test_vectors.json")
        val content = Files.readAllBytes(path).decodeToString()
        return json.decodeFromString(CryptoVectors.serializer(), content)
    }

    private fun locateRepositoryRoot(): Path {
        var current = Path.of("").toAbsolutePath()
        var attempts = 0
        while (attempts < 10) {
            val candidate = current.resolve("tests/crypto_test_vectors.json")
            if (Files.exists(candidate)) {
                return current
            }
            current = current.parent ?: break
            attempts++
        }
        error("Unable to locate crypto_test_vectors.json")
    }

    @Serializable
    private data class CryptoVectors(
        @SerialName("test_cases") val testCases: List<TestCase>,
        @SerialName("key_agreement") val keyAgreement: KeyAgreement
    ) {
        @Serializable
        data class TestCase(
            val name: String,
            @SerialName("plaintext_base64") val plaintextBase64: String,
            @SerialName("key_base64") val keyBase64: String,
            @SerialName("nonce_base64") val nonceBase64: String,
            @SerialName("aad_base64") val aadBase64: String,
            @SerialName("ciphertext_base64") val ciphertextBase64: String,
            @SerialName("tag_base64") val tagBase64: String
        ) {
            val plaintext: ByteArray get() = decode(plaintextBase64)
            val key: ByteArray get() = decode(keyBase64)
            val nonce: ByteArray get() = decode(nonceBase64)
            val aad: ByteArray get() = decode(aadBase64)
            val ciphertext: ByteArray get() = decode(ciphertextBase64)
            val tag: ByteArray get() = decode(tagBase64)
        }

        @Serializable
        data class KeyAgreement(
            @SerialName("alice_private_base64") val alicePrivateBase64: String,
            @SerialName("alice_public_base64") val alicePublicBase64: String,
            @SerialName("bob_private_base64") val bobPrivateBase64: String,
            @SerialName("bob_public_base64") val bobPublicBase64: String,
            @SerialName("shared_key_base64") val sharedKeyBase64: String
        ) {
            val alicePrivate: ByteArray get() = decode(alicePrivateBase64)
            val alicePublic: ByteArray get() = decode(alicePublicBase64)
            val bobPrivate: ByteArray get() = decode(bobPrivateBase64)
            val bobPublic: ByteArray get() = decode(bobPublicBase64)
            val sharedKey: ByteArray get() = decode(sharedKeyBase64)
        }

        companion object {
            private fun decode(value: String): ByteArray =
                if (value.isEmpty()) ByteArray(0) else Base64.getDecoder().decode(value)
        }
    }
}
