package com.hypo.clipboard.pairing

import com.hypo.clipboard.util.formattedAsKB
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
            Log.d(TAG, "Pairing initiate: Decoded payload - version=${payload.version}, deviceId=${payload.peerDeviceId}")
            Log.d(TAG, "Pairing initiate: publicKey length=${payload.peerPublicKey.length}, signingPublicKey length=${payload.peerSigningPublicKey.length}, signature length=${payload.signature.length}")
            
            validatePayload(payload)
            
            // Validate that public key is present and non-empty
            val publicKeyString = payload.peerPublicKey
            if (publicKeyString.isEmpty()) {
                throw PairingException("Missing peer public key in pairing payload")
            }
            
            val peerPublicKey = Base64.decode(publicKeyString, Base64.DEFAULT)
            Log.d(TAG, "Pairing initiate: Decoded peerPublicKey, ${peerPublicKey.size.formattedAsKB()}")
            
            // Validate key size
            if (peerPublicKey.size != 32) {
                throw PairingException("Invalid peer public key size: ${peerPublicKey.size} bytes (expected 32 bytes)")
            }
            
            // For LAN auto-discovery, skip signature verification
            // (we rely on TLS fingerprint verification instead)
            if (payload.signature != "LAN_AUTO_DISCOVERY") {
                val signingKey = Base64.decode(payload.peerSigningPublicKey, Base64.DEFAULT)
                Log.d(TAG, "Pairing initiate: Decoded signingPublicKey, ${signingKey.size.formattedAsKB()} (expected 32 for Ed25519)")
                
                Log.d(TAG, "Pairing initiate: Starting signature verification...")
                verifySignature(payload, signingKey)
                Log.d(TAG, "Pairing initiate: Signature verification SUCCESS")
                // Store the signing key for future verification
                trustStore.store(payload.peerDeviceId, signingKey)
            } else {
                Log.d(TAG, "Pairing initiate: Skipping signature verification for LAN auto-discovery")
                // Still store the signing key if available for future use
                if (payload.peerSigningPublicKey.isNotEmpty()) {
                    try {
                        val signingKey = Base64.decode(payload.peerSigningPublicKey, Base64.DEFAULT)
                        if (signingKey.size == 32) {
                            trustStore.store(payload.peerDeviceId, signingKey)
                            Log.d(TAG, "Pairing initiate: Stored signing public key for future verification")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Could not decode signing key: ${e.message}")
                    }
                }
            }

            val initiatorPrivateKey = X25519.generatePrivateKey()
            val initiatorPublicKey = X25519.publicFromPrivate(initiatorPrivateKey)
            val peerAgreementKey = peerPublicKey
            val sharedKey = cryptoService.deriveKey(initiatorPrivateKey, peerAgreementKey)

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
                initiatorDeviceId = identity.deviceId,
                initiatorDeviceName = identity.deviceName,
                initiatorPublicKey = Base64.encodeToString(initiatorPublicKey, Base64.NO_WRAP),
                nonce = Base64.encodeToString(encrypted.nonce, Base64.NO_WRAP),
                ciphertext = Base64.encodeToString(encrypted.ciphertext, Base64.NO_WRAP),
                tag = Base64.encodeToString(encrypted.tag, Base64.NO_WRAP)
            )

            PairingInitiationResult.Success(
                state = PairingSessionState(
                    payload = payload,
                    androidPrivateKey = initiatorPrivateKey,
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
                val macPublicKey = Base64.decode(claim.initiatorPublicKey, Base64.DEFAULT)
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
                    initiatorDeviceId = identity.deviceId,
                    initiatorDeviceName = identity.deviceName,
                    initiatorPublicKey = Base64.encodeToString(androidPublicKey, Base64.NO_WRAP),
                    nonce = Base64.encodeToString(encrypted.nonce, Base64.NO_WRAP),
                    ciphertext = Base64.encodeToString(encrypted.ciphertext, Base64.NO_WRAP),
                    tag = Base64.encodeToString(encrypted.tag, Base64.NO_WRAP)
                )
                val payload = PairingPayload(
                    version = "1",
                    peerDeviceId = claim.initiatorDeviceId,
                    peerPublicKey = claim.initiatorPublicKey,
                    peerSigningPublicKey = "", // TODO: Add to PairingClaim when remote pairing supports signing
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
                    aad = ack.responderDeviceId.toByteArray()
                )
                val payload = json.decodeFromString<PairingAckPayload>(plaintext.decodeToString())
                val expectedHash = hash(state.challengeSecret)
                val providedHash = Base64.decode(payload.responseHash, Base64.DEFAULT)
                require(expectedHash.contentEquals(providedHash)) { "Invalid challenge response" }
                val issuedAt = Instant.parse(payload.issuedAt)
                require(Duration.between(issuedAt, clock.instant()).abs() <= Duration.ofMinutes(5)) {
                    "ACK timestamp out of range"
                }

                // Migrate device ID to pure UUID format (remove prefix if present)
                val migratedDeviceId = migrateDeviceId(state.payload.peerDeviceId)
                deviceKeyStore.saveKey(migratedDeviceId, state.sharedKey)
                PairingCompletionResult.Success(migratedDeviceId, ack.responderDeviceName)
            }.getOrElse { throwable ->
                PairingCompletionResult.Failure(throwable.message ?: "Pairing failed")
            }
        }

    private fun validatePayload(payload: PairingPayload) {
        require(payload.version == "1") { "Unsupported pairing version" }
        val now = clock.instant()
        require(payload.issuedInstant() <= now.plusSeconds(60)) { "Payload not yet valid" }
        require(payload.expiryInstant() >= now) { "Pairing QR expired" }
        
        // Handle platform-prefixed formats (macos-{UUID}, android-{UUID}, etc.) and legacy "{UUID}" formats
        val deviceId = payload.peerDeviceId
        val uuidString = when {
            deviceId.startsWith("macos-") -> deviceId.substring(6) // Remove "macos-" prefix
            deviceId.startsWith("android-") -> deviceId.substring(8) // Remove "android-" prefix
            deviceId.startsWith("ios-") -> deviceId.substring(4) // Remove "ios-" prefix
            deviceId.startsWith("windows-") -> deviceId.substring(8) // Remove "windows-" prefix
            deviceId.startsWith("linux-") -> deviceId.substring(6) // Remove "linux-" prefix
            else -> deviceId // Legacy format without prefix
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
            Log.d(TAG, "verifySignature: Encoded payload for verification: ${encoded.size.formattedAsKB()}")
            Log.d(TAG, "verifySignature: Payload JSON: ${String(encoded)}")
            
            val signature = Base64.decode(payload.signature, Base64.DEFAULT)
            Log.d(TAG, "verifySignature: Decoded signature: ${signature.size.formattedAsKB()} (expected 64 for Ed25519)")
            
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
        sortedMap["peer_device_id"] = payload.peerDeviceId
        sortedMap["peer_pub_key"] = payload.peerPublicKey
        sortedMap["peer_signing_pub_key"] = payload.peerSigningPublicKey
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


    private fun hash(data: ByteArray): ByteArray {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        return digest.digest(data)
    }
    
    private fun migrateDeviceId(deviceId: String): String {
        return deviceId.removePrefix("macos-").removePrefix("android-")
    }
    
    /**
     * Handle an incoming pairing challenge and generate an ACK response.
     * This is called when this device receives a pairing challenge from another device.
     * 
     * @param challengeJson JSON string containing the PairingChallengeMessage
     * @param responderPrivateKey The responder's private key (for key agreement)
     * @return JSON string containing the PairingAckMessage, or null if handling failed
     */
    suspend fun handleChallengeAsInitiator(
        challengeJson: String,
        sessionState: PairingSessionState
    ): String? = withContext(Dispatchers.Default) {
        runCatching {
            Log.d(TAG, "handleChallengeAsInitiator: Parsing challenge JSON (${challengeJson.length} chars)")
            val challenge = json.decodeFromString<PairingChallengeMessage>(challengeJson)
            Log.d(TAG, "handleChallengeAsInitiator: Decoded challenge - responder=${challenge.initiatorDeviceName}, challengeId=${challenge.challengeId}")
            
            // When we're the initiator, the challenge comes from the responder
            // The challenge.initiatorPublicKey is actually the responder's public key
            // We need to derive the shared key from responder's public key and our private key
            val responderPublicKey = Base64.decode(challenge.initiatorPublicKey, Base64.DEFAULT)
            if (responderPublicKey.size != 32) {
                throw PairingException("Invalid responder public key size: ${responderPublicKey.size} bytes (expected 32)")
            }
            
            val sharedKey = cryptoService.deriveKey(sessionState.androidPrivateKey, responderPublicKey)
            Log.d(TAG, "handleChallengeAsInitiator: Derived shared key (${sharedKey.size.formattedAsKB()})")
            
            // Decrypt the challenge
            val encrypted = EncryptedData(
                ciphertext = Base64.decode(challenge.ciphertext, Base64.DEFAULT),
                nonce = Base64.decode(challenge.nonce, Base64.DEFAULT),
                tag = Base64.decode(challenge.tag, Base64.DEFAULT)
            )
            val plaintext = cryptoService.decrypt(
                encrypted = encrypted,
                key = sharedKey,
                aad = challenge.initiatorDeviceId.toByteArray()
            )
            val challengePayload = json.decodeFromString<PairingChallengePayload>(plaintext.decodeToString())
            val expectedHash = hash(Base64.decode(challengePayload.challenge, Base64.DEFAULT))
            
            // Generate ACK
            val ackPayload = PairingAckPayload(
                responseHash = Base64.encodeToString(expectedHash, Base64.NO_WRAP),
                issuedAt = clock.instant().toString()
            )
            val ackBytes = json.encodeToString(ackPayload).toByteArray()
            val encryptedAck = cryptoService.encrypt(
                plaintext = ackBytes,
                key = sharedKey,
                aad = identity.deviceId.toByteArray()
            )
            val ackMessage = PairingAckMessage(
                challengeId = challenge.challengeId,
                responderDeviceId = identity.deviceId,
                responderDeviceName = identity.deviceName,
                nonce = Base64.encodeToString(encryptedAck.nonce, Base64.NO_WRAP),
                ciphertext = Base64.encodeToString(encryptedAck.ciphertext, Base64.NO_WRAP),
                tag = Base64.encodeToString(encryptedAck.tag, Base64.NO_WRAP)
            )
            
            // Store the shared key for future communication
            val migratedDeviceId = migrateDeviceId(challenge.initiatorDeviceId)
            deviceKeyStore.saveKey(migratedDeviceId, sharedKey)
            trustStore.store(migratedDeviceId, responderPublicKey)
            
            Log.d(TAG, "handleChallengeAsInitiator: Generated ACK JSON (${json.encodeToString(ackMessage).length} chars)")
            json.encodeToString(ackMessage)
        }.getOrElse { throwable ->
            Log.e(TAG, "handleChallengeAsInitiator FAILED: ${throwable.message}", throwable)
            null
        }
    }

    suspend fun handleChallenge(challengeJson: String, responderPrivateKey: ByteArray): String? = 
        withContext(Dispatchers.Default) {
            runCatching {
                Log.d(TAG, "handleChallenge: Parsing challenge JSON (${challengeJson.length} chars)")
                val challenge = json.decodeFromString<PairingChallengeMessage>(challengeJson)
                Log.d(TAG, "handleChallenge: Decoded challenge - initiator=${challenge.initiatorDeviceName}, challengeId=${challenge.challengeId}")
                
                // Derive shared key using responder's private key and initiator's public key
                val initiatorPublicKey = Base64.decode(challenge.initiatorPublicKey, Base64.DEFAULT)
                if (initiatorPublicKey.size != 32) {
                    throw PairingException("Invalid initiator public key size: ${initiatorPublicKey.size} bytes (expected 32)")
                }
                
                val sharedKey = cryptoService.deriveKey(responderPrivateKey, initiatorPublicKey)
                Log.d(TAG, "handleChallenge: Derived shared key (${sharedKey.size.formattedAsKB()})")
                
                // Decrypt the challenge
                val encrypted = EncryptedData(
                    ciphertext = Base64.decode(challenge.ciphertext, Base64.DEFAULT),
                    nonce = Base64.decode(challenge.nonce, Base64.DEFAULT),
                    tag = Base64.decode(challenge.tag, Base64.DEFAULT)
                )
                val plaintext = cryptoService.decrypt(
                    encrypted = encrypted,
                    key = sharedKey,
                    aad = challenge.initiatorDeviceId.toByteArray()
                )
                val challengePayload = json.decodeFromString<PairingChallengePayload>(plaintext.decodeToString())
                Log.d(TAG, "handleChallenge: Decrypted challenge payload")
                
                // Compute response hash
                val challengeSecret = Base64.decode(challengePayload.challenge, Base64.DEFAULT)
                val responseHash = hash(challengeSecret)
                val responseHashBase64 = Base64.encodeToString(responseHash, Base64.NO_WRAP)
                
                // Create ACK payload
                val ackPayload = PairingAckPayload(
                    responseHash = responseHashBase64,
                    issuedAt = clock.instant().toString()
                )
                val ackPayloadBytes = json.encodeToString(ackPayload).toByteArray()
                
                // Encrypt ACK payload
                val ackEncrypted = cryptoService.encrypt(
                    plaintext = ackPayloadBytes,
                    key = sharedKey,
                    aad = identity.deviceId.toByteArray()
                )
                
                // Create ACK message
                val ack = PairingAckMessage(
                    challengeId = challenge.challengeId,
                    responderDeviceId = identity.deviceId,
                    responderDeviceName = identity.deviceName,
                    nonce = Base64.encodeToString(ackEncrypted.nonce, Base64.NO_WRAP),
                    ciphertext = Base64.encodeToString(ackEncrypted.ciphertext, Base64.NO_WRAP),
                    tag = Base64.encodeToString(ackEncrypted.tag, Base64.NO_WRAP)
                )
                
                // Store shared key for future communication
                val migratedDeviceId = migrateDeviceId(challenge.initiatorDeviceId)
                deviceKeyStore.saveKey(migratedDeviceId, sharedKey)
                Log.d(TAG, "handleChallenge: Saved shared key for device: $migratedDeviceId")
                
                // Return ACK as JSON
                val ackJson = json.encodeToString(ack)
                Log.d(TAG, "handleChallenge: Generated ACK JSON (${ackJson.length} chars)")
                ackJson
            }.getOrElse { throwable ->
                Log.e(TAG, "handleChallenge FAILED: ${throwable.message}", throwable)
                null
            }
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
    data class Success(val peerDeviceId: String, val peerDeviceName: String) : PairingCompletionResult
    data class Failure(val reason: String) : PairingCompletionResult
}
