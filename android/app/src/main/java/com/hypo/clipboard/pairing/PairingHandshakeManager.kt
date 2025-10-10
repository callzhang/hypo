package com.hypo.clipboard.pairing

import android.util.Base64
import com.google.crypto.tink.subtle.Ed25519Verify
import com.google.crypto.tink.subtle.X25519
import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.crypto.EncryptedData
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.DeviceKeyStore
import java.security.GeneralSecurityException
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class PairingHandshakeManager @Inject constructor(
    private val cryptoService: CryptoService,
    private val deviceKeyStore: DeviceKeyStore,
    private val trustStore: PairingTrustStore,
    private val identity: DeviceIdentity,
    private val clock: Clock = Clock.systemUTC(),
    private val json: Json = Json { ignoreUnknownKeys = true }
) {
    suspend fun initiate(qrContent: String): PairingInitiationResult = withContext(Dispatchers.Default) {
        runCatching {
            val payload = json.decodeFromString<PairingPayload>(qrContent)
            validatePayload(payload)
            val macPublicKey = Base64.decode(payload.macPublicKey, Base64.DEFAULT)
            val signingKey = trustStore.publicKey(payload.macDeviceId)
                ?: throw PairingException("Untrusted macOS device. Signature key missing.")
            verifySignature(payload, signingKey)

            val androidPrivateKey = X25519.generatePrivateKey()
            val androidPublicKey = X25519.publicFromPrivate(androidPrivateKey)
            val macAgreementKey = macPublicKey
            val sharedKey = cryptoService.deriveKey(androidPrivateKey, macAgreementKey)

            val challengeSecret = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            val challengePayload = PairingChallengePayload(
                challenge = Base64.encodeToString(challengeSecret, Base64.NO_WRAP),
                timestamp = clock.instant().toString()
            )
            val challengeBytes = json.encodeToString(challengePayload).toByteArray()
            val encrypted = cryptoService.encrypt(
                plaintext = challengeBytes,
                key = sharedKey,
                aad = identity.deviceId.toByteArray()
            )
            val challengeMessage = PairingChallengeMessage(
                androidDeviceId = identity.deviceId,
                androidDeviceName = identity.deviceName,
                androidPublicKey = Base64.encodeToString(androidPublicKey, Base64.NO_WRAP),
                nonce = Base64.encodeToString(encrypted.nonce, Base64.NO_WRAP),
                ciphertext = Base64.encodeToString(encrypted.ciphertext, Base64.NO_WRAP),
                tag = Base64.encodeToString(encrypted.tag, Base64.NO_WRAP)
            )

            PairingInitiationResult.Success(
                state = PairingSessionState(
                    payload = payload,
                    androidPrivateKey = androidPrivateKey,
                    sharedKey = sharedKey,
                    challengeSecret = challengeSecret,
                    challenge = challengeMessage
                )
            )
        }.getOrElse { throwable ->
            PairingInitiationResult.Failure(throwable.message ?: "Unable to start pairing")
        }
    }

    suspend fun initiateRemote(claim: PairingClaim, androidPrivateKey: ByteArray): PairingInitiationResult =
        withContext(Dispatchers.Default) {
            runCatching {
                val macPublicKey = Base64.decode(claim.macPublicKey, Base64.DEFAULT)
                val androidPublicKey = X25519.publicFromPrivate(androidPrivateKey)
                val sharedKey = cryptoService.deriveKey(androidPrivateKey, macPublicKey)

                val challengeSecret = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
                val challengePayload = PairingChallengePayload(
                    challenge = Base64.encodeToString(challengeSecret, Base64.NO_WRAP),
                    timestamp = clock.instant().toString()
                )
                val challengeBytes = json.encodeToString(challengePayload).toByteArray()
                val encrypted = cryptoService.encrypt(
                    plaintext = challengeBytes,
                    key = sharedKey,
                    aad = identity.deviceId.toByteArray()
                )
                val challengeMessage = PairingChallengeMessage(
                    androidDeviceId = identity.deviceId,
                    androidDeviceName = identity.deviceName,
                    androidPublicKey = Base64.encodeToString(androidPublicKey, Base64.NO_WRAP),
                    nonce = Base64.encodeToString(encrypted.nonce, Base64.NO_WRAP),
                    ciphertext = Base64.encodeToString(encrypted.ciphertext, Base64.NO_WRAP),
                    tag = Base64.encodeToString(encrypted.tag, Base64.NO_WRAP)
                )
                val payload = PairingPayload(
                    version = "1",
                    macDeviceId = claim.macDeviceId,
                    macPublicKey = claim.macPublicKey,
                    service = "",
                    port = 0,
                    relayHint = null,
                    issuedAt = clock.instant().toString(),
                    expiresAt = claim.expiresAt.toString(),
                    signature = ""
                )

                PairingInitiationResult.Success(
                    PairingSessionState(
                        payload = payload,
                        androidPrivateKey = androidPrivateKey,
                        sharedKey = sharedKey,
                        challengeSecret = challengeSecret,
                        challenge = challengeMessage
                    )
                )
            }.getOrElse { throwable ->
                PairingInitiationResult.Failure(throwable.message ?: "Unable to start pairing")
            }
        }

    suspend fun complete(state: PairingSessionState, ackJson: String): PairingCompletionResult =
        withContext(Dispatchers.Default) {
            runCatching {
                val ack = json.decodeFromString<PairingAckMessage>(ackJson)
                require(ack.challengeId == state.challenge.challengeId) { "Challenge mismatch" }

                val encrypted = EncryptedData(
                    ciphertext = Base64.decode(ack.ciphertext, Base64.DEFAULT),
                    nonce = Base64.decode(ack.nonce, Base64.DEFAULT),
                    tag = Base64.decode(ack.tag, Base64.DEFAULT)
                )
                val plaintext = cryptoService.decrypt(
                    encrypted = encrypted,
                    key = state.sharedKey,
                    aad = ack.macDeviceId.toByteArray()
                )
                val payload = json.decodeFromString<PairingAckPayload>(plaintext.decodeToString())
                val expectedHash = hash(state.challengeSecret)
                val providedHash = Base64.decode(payload.responseHash, Base64.DEFAULT)
                require(expectedHash.contentEquals(providedHash)) { "Invalid challenge response" }
                val issuedAt = Instant.parse(payload.issuedAt)
                require(Duration.between(issuedAt, clock.instant()).abs() <= Duration.ofMinutes(5)) {
                    "ACK timestamp out of range"
                }

                deviceKeyStore.saveKey(state.payload.macDeviceId, state.sharedKey)
                PairingCompletionResult.Success(state.payload.macDeviceId, ack.macDeviceName)
            }.getOrElse { throwable ->
                PairingCompletionResult.Failure(throwable.message ?: "Pairing failed")
            }
        }

    private fun validatePayload(payload: PairingPayload) {
        require(payload.version == "1") { "Unsupported pairing version" }
        val now = clock.instant()
        require(payload.issuedInstant() <= now.plusSeconds(60)) { "Payload not yet valid" }
        require(payload.expiryInstant() >= now) { "Pairing QR expired" }
        UUID.fromString(payload.macDeviceId)
    }

    private fun verifySignature(payload: PairingPayload, signingKey: ByteArray) {
        val verifier = Ed25519Verify(signingKey)
        val stripped = payload.copy(signature = "")
        val encoded = json.encodeToString(stripped).toByteArray()
        val signature = Base64.decode(payload.signature, Base64.DEFAULT)
        try {
            verifier.verify(signature, encoded)
        } catch (error: GeneralSecurityException) {
            throw PairingException("Invalid QR signature")
        }
    }

    private suspend fun CryptoService.encrypt(
        plaintext: ByteArray,
        key: ByteArray,
        aad: ByteArray
    ): EncryptedData = run {
        runCatching { encrypt(plaintext, key, aad) }.getOrElse {
            throw PairingException("Encryption failed")
        }
    }

    private suspend fun CryptoService.decrypt(
        encrypted: EncryptedData,
        key: ByteArray,
        aad: ByteArray
    ): ByteArray = run {
        runCatching { decrypt(encrypted, key, aad) }.getOrElse {
            throw PairingException("Decryption failed")
        }
    }

    private suspend fun CryptoService.deriveKey(privateKey: ByteArray, publicKey: ByteArray): ByteArray =
        runCatching { deriveKey(privateKey, publicKey) }.getOrElse {
            throw PairingException("Key agreement failed")
        }

    private fun hash(data: ByteArray): ByteArray {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        return digest.digest(data)
    }
}

class PairingException(message: String) : IllegalStateException(message)

data class PairingSessionState(
    val payload: PairingPayload,
    val androidPrivateKey: ByteArray,
    val sharedKey: ByteArray,
    val challengeSecret: ByteArray,
    val challenge: PairingChallengeMessage
)

sealed interface PairingInitiationResult {
    data class Success(val state: PairingSessionState) : PairingInitiationResult
    data class Failure(val reason: String) : PairingInitiationResult
}

sealed interface PairingCompletionResult {
    data class Success(val macDeviceId: String, val macDeviceName: String) : PairingCompletionResult
    data class Failure(val reason: String) : PairingCompletionResult
}
