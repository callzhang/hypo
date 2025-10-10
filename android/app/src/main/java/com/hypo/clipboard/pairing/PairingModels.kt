package com.hypo.clipboard.pairing

import java.time.Instant
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PairingPayload(
    @SerialName("ver") val version: String,
    @SerialName("mac_device_id") val macDeviceId: String,
    @SerialName("mac_pub_key") val macPublicKey: String,
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
    @SerialName("android_device_id") val androidDeviceId: String,
    @SerialName("android_device_name") val androidDeviceName: String,
    @SerialName("android_pub_key") val androidPublicKey: String,
    val nonce: String,
    val ciphertext: String,
    val tag: String
)

@Serializable
data class PairingAckMessage(
    @SerialName("challenge_id") val challengeId: String,
    @SerialName("mac_device_id") val macDeviceId: String,
    @SerialName("mac_device_name") val macDeviceName: String,
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
    @SerialName("issued_at") val issuedAt: String
)
