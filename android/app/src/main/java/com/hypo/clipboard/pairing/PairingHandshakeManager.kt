package com.hypo.clipboard.pairing

import android.util.Base64
import android.util.Log
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
    private val json: Json = Json { 
        ignoreUnknownKeys = true
        encodeDefaults = false
    }
) {
    suspend fun initiate(qrContent: String): PairingInitiationResult = withContext(Dispatchers.Default) {
        runCatching {
            Log.d(TAG, "Pairing initiate: Parsing QR content (${qrContent.length} chars)")
            val payload = json.decodeFromString<PairingPayload>(qrContent)
            Log.d(TAG, "Pairing initiate: Decoded payload - version=${payload.version}, macDeviceId=${payload.macDeviceId}")
            Log.d(TAG, "Pairing initiate: macPublicKey length=${payload.macPublicKey.length}, macSigningPublicKey length=${payload.macSigningPublicKey.length}, signature length=${payload.signature.length}")
            
            validatePayload(payload)
            val macPublicKey = Base64.decode(payload.macPublicKey, Base64.DEFAULT)
            Log.d(TAG, "Pairing initiate: Decoded macPublicKey, ${macPublicKey.size} bytes")
            
            // For LAN auto-discovery, skip signature verification
            // (we rely on TLS fingerprint verification instead)
            if (payload.signature != "LAN_AUTO_DISCOVERY") {
                val signingKey = Base64.decode(payload.macSigningPublicKey, Base64.DEFAULT)
                Log.d(TAG, "Pairing initiate: Decoded macSigningPublicKey, ${signingKey.size} bytes (expected 32 for Ed25519)")
                
                Log.d(TAG, "Pairing initiate: Starting signature verification...")
                verifySignature(payload, signingKey)
                Log.d(TAG, "Pairing initiate: Signature verification SUCCESS")
                // Store the signing key for future verification
                trustStore.store(payload.macDeviceId, signingKey)
            } else {
                Log.d(TAG, "Pairing initiate: Skipping signature verification for LAN auto-discovery")
                // Still store the signing key if available for future use
                if (payload.macSigningPublicKey.isNotEmpty()) {
                    try {
                        val signingKey = Base64.decode(payload.macSigningPublicKey, Base64.DEFAULT)
                        if (signingKey.size == 32) {
                            trustStore.store(payload.macDeviceId, signingKey)
                            Log.d(TAG, "Pairing initiate: Stored signing public key for future verification")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Could not decode signing key: ${e.message}")
                    }
                }
            }

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
            Log.e(TAG, "Pairing initiate FAILED: ${throwable.message}", throwable)
            PairingInitiationResult.Failure(throwable.message ?: "Unable to start pairing")
        }
    }
    
    companion object {
        private const val TAG = "PairingHandshake"
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
                    macSigningPublicKey = "", // TODO: Add to PairingClaim when remote pairing supports signing
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
        
        // Handle both "macos-{UUID}" and legacy "{UUID}" formats
        val uuidString = if (payload.macDeviceId.startsWith("macos-")) {
            payload.macDeviceId.substring(6) // Remove "macos-" prefix
        } else {
            payload.macDeviceId // Legacy format without prefix
        }
        UUID.fromString(uuidString)
    }

    private fun verifySignature(payload: PairingPayload, signingKey: ByteArray) {
        Log.d(TAG, "verifySignature: Creating Ed25519 verifier with ${signingKey.size}-byte public key")
        try {
            val verifier = Ed25519Verify(signingKey)
            Log.d(TAG, "verifySignature: Ed25519 verifier created successfully")
            
            // Encode with sorted keys to match Swift's JSONEncoder.sortedKeys
            val stripped = payload.copy(signature = "")
            val encoded = encodeWithSortedKeys(stripped)
            Log.d(TAG, "verifySignature: Encoded payload for verification: ${encoded.size} bytes")
            Log.d(TAG, "verifySignature: Payload JSON: ${String(encoded)}")
            
            val signature = Base64.decode(payload.signature, Base64.DEFAULT)
            Log.d(TAG, "verifySignature: Decoded signature: ${signature.size} bytes (expected 64 for Ed25519)")
            
            verifier.verify(signature, encoded)
            Log.d(TAG, "verifySignature: Signature verification PASSED")
        } catch (error: GeneralSecurityException) {
            Log.e(TAG, "verifySignature: Signature verification FAILED - ${error.javaClass.simpleName}: ${error.message}", error)
            Log.e(TAG, "verifySignature: Signing key size=${signingKey.size}, payload.signature length=${payload.signature.length}")
            throw PairingException("Invalid QR signature: ${error.message}")
        } catch (error: Exception) {
            Log.e(TAG, "verifySignature: Unexpected error - ${error.javaClass.simpleName}: ${error.message}", error)
            throw PairingException("Signature verification error: ${error.message}")
        }
    }

    /**
     * Encode PairingPayload with sorted keys to match Swift's JSONEncoder.sortedKeys behavior.
     * This ensures signature verification works correctly across platforms.
     */
    private fun encodeWithSortedKeys(payload: PairingPayload): ByteArray {
        val sortedMap = sortedMapOf<String, Any?>()
        sortedMap["expires_at"] = payload.expiresAt
        sortedMap["issued_at"] = payload.issuedAt
        sortedMap["mac_device_id"] = payload.macDeviceId
        sortedMap["mac_pub_key"] = payload.macPublicKey
        sortedMap["mac_signing_pub_key"] = payload.macSigningPublicKey
        sortedMap["port"] = payload.port
        if (payload.relayHint != null) {
            sortedMap["relay_hint"] = payload.relayHint
        }
        sortedMap["service"] = payload.service
        sortedMap["signature"] = payload.signature
        sortedMap["ver"] = payload.version
        
        // Use org.json.JSONObject which maintains insertion order
        val jsonObject = org.json.JSONObject()
        sortedMap.forEach { (key, value) -> jsonObject.put(key, value) }
        return jsonObject.toString().toByteArray()
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
