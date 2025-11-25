package com.hypo.clipboard.pairing

import java.time.Instant
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PairingPayload(
    @SerialName("ver") val version: String,
    @SerialName("peer_device_id") val peerDeviceId: String,
    @SerialName("peer_pub_key") val peerPublicKey: String,
    @SerialName("peer_signing_pub_key") val peerSigningPublicKey: String,
    val service: String,
    val port: Int,
    @SerialName("relay_hint") val relayHint: String? = null,
    @SerialName("issued_at") val issuedAt: String,
    @SerialName("expires_at") val expiresAt: String,
    val signature: String
) {
    fun issuedInstant(): Instant = Instant.parse(issuedAt)
    fun expiryInstant(): Instant = Instant.parse(expiresAt)
}

@Serializable
data class PairingChallengeMessage(
    @SerialName("challenge_id") val challengeId: String = UUID.randomUUID().toString(),
    @SerialName("initiator_device_id") val initiatorDeviceId: String,
    @SerialName("initiator_device_name") val initiatorDeviceName: String,
    @SerialName("initiator_pub_key") val initiatorPublicKey: String,
    val nonce: String,
    val ciphertext: String,
    val tag: String
)

@Serializable
data class PairingAckMessage(
    @SerialName("challenge_id") val challengeId: String,
    @SerialName("responder_device_id") val responderDeviceId: String,
    @SerialName("responder_device_name") val responderDeviceName: String,
    val nonce: String,
    val ciphertext: String,
    val tag: String
)

@Serializable
data class PairingChallengePayload(
    val challenge: String,
    val timestamp: String
)

@Serializable
data class PairingAckPayload(
    @SerialName("response_hash") val responseHash: String,
    @SerialName("issued_at") val issuedAt: String,
    @SerialName("responder_pub_key") val responderPublicKey: String? = null // Ephemeral public key for key rotation (optional for backward compatibility)
)
