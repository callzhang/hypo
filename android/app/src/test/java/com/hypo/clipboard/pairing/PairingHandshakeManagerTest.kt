package com.hypo.clipboard.pairing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.crypto.tink.subtle.X25519
import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.DeviceKeyStore
import java.security.MessageDigest
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PairingHandshakeManagerTest {
    private lateinit var context: Context
    private lateinit var trustStore: PairingTrustStore
    private lateinit var identity: DeviceIdentity
    private lateinit var keyStore: RecordingKeyStore
    private val json = Json { prettyPrint = true }
    private val clock = Clock.fixed(Instant.parse("2024-01-01T00:00:00Z"), ZoneOffset.UTC)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        trustStore = PairingTrustStore(context)
        identity = DeviceIdentity(context)
        keyStore = RecordingKeyStore()
    }

    @Test
    fun handshakeStoresKeyOnSuccess() = runTest {
        val macDeviceId = "12345678-90ab-cdef-1234-567890abcdef"

        val macAgreementPrivate = X25519.generatePrivateKey()
        val macAgreementPublic = X25519.publicFromPrivate(macAgreementPrivate)

        val payload = PairingPayload(
            version = "1",
            peerDeviceId = macDeviceId,
            peerPublicKey = Base64.getEncoder().encodeToString(macAgreementPublic),
            peerSigningPublicKey = "",
            service = "_hypo._tcp.local",
            port = 7010,
            relayHint = "https://relay",
            issuedAt = clock.instant().toString(),
            expiresAt = clock.instant().plusSeconds(300).toString(),
            signature = "LAN_AUTO_DISCOVERY"
        )
        val signedPayloadJson = json.encodeToString(payload)

        val crypto = CryptoService()
        val manager = PairingHandshakeManager(
            cryptoService = crypto,
            deviceKeyStore = keyStore,
            trustStore = trustStore,
            identity = identity,
            clock = clock,
            json = json
        )

        val initiation = manager.initiatePayload(signedPayloadJson)
        assertTrue(initiation is PairingInitiationResult.Success)
        val state = (initiation as PairingInitiationResult.Success).state

        val ackPayload = PairingAckPayload(
            responseHash = Base64.getEncoder().encodeToString(hash(state.challengeSecret)),
            issuedAt = clock.instant().toString()
        )
        val ackCipher = crypto.encrypt(
            plaintext = json.encodeToString(ackPayload).toByteArray(),
            key = state.sharedKey,
            aad = macDeviceId.toByteArray()
        )
        val ack = PairingAckMessage(
            challengeId = state.challenge.challengeId,
            responderDeviceId = macDeviceId,
            responderDeviceName = "Test Mac",
            nonce = Base64.getEncoder().encodeToString(ackCipher.nonce),
            ciphertext = Base64.getEncoder().encodeToString(ackCipher.ciphertext),
            tag = Base64.getEncoder().encodeToString(ackCipher.tag)
        )
        val ackJson = json.encodeToString(ack)

        val completion = manager.complete(state, ackJson)
        assertTrue(completion is PairingCompletionResult.Success)
        assertEquals(macDeviceId, (completion as PairingCompletionResult.Success).peerDeviceId)
        assertTrue(keyStore.savedKeys.containsKey(macDeviceId))
    }

    @Test
    fun remoteHandshakeCompletes() = runTest {
        val macAgreementPrivate = X25519.generatePrivateKey()
        val macAgreementPublic = X25519.publicFromPrivate(macAgreementPrivate)
        val macDeviceId = "12345678-90ab-cdef-1234-567890abcdef"
        val claim = PairingClaim(
            initiatorDeviceId = macDeviceId,
            initiatorDeviceName = "Test Mac",
            initiatorPublicKey = Base64.getEncoder().encodeToString(macAgreementPublic),
            expiresAt = clock.instant().plusSeconds(120)
        )

        val androidPrivateKey = X25519.generatePrivateKey()

        val crypto = CryptoService()
        val manager = PairingHandshakeManager(
            cryptoService = crypto,
            deviceKeyStore = keyStore,
            trustStore = trustStore,
            identity = identity,
            clock = clock,
            json = json
        )

        val initiation = manager.initiateRemote(claim, androidPrivateKey)
        assertTrue(initiation is PairingInitiationResult.Success)
        val state = (initiation as PairingInitiationResult.Success).state

        val ackPayload = PairingAckPayload(
            responseHash = Base64.getEncoder().encodeToString(hash(state.challengeSecret)),
            issuedAt = clock.instant().toString()
        )
        val ackCipher = crypto.encrypt(
            plaintext = json.encodeToString(ackPayload).toByteArray(),
            key = state.sharedKey,
            aad = macDeviceId.toByteArray()
        )
        val ack = PairingAckMessage(
            challengeId = state.challenge.challengeId,
            responderDeviceId = macDeviceId,
            responderDeviceName = "Test Mac",
            nonce = Base64.getEncoder().encodeToString(ackCipher.nonce),
            ciphertext = Base64.getEncoder().encodeToString(ackCipher.ciphertext),
            tag = Base64.getEncoder().encodeToString(ackCipher.tag)
        )
        val ackJson = json.encodeToString(ack)

        val completion = manager.complete(state, ackJson)
        assertTrue(completion is PairingCompletionResult.Success)
        assertEquals(macDeviceId, (completion as PairingCompletionResult.Success).peerDeviceId)
        assertTrue(keyStore.savedKeys.containsKey(macDeviceId))
    }

    private fun hash(data: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(data)
    }

    private class RecordingKeyStore : DeviceKeyStore {
        val savedKeys = mutableMapOf<String, ByteArray>()
        override suspend fun saveKey(deviceId: String, key: ByteArray) {
            savedKeys[deviceId] = key
        }

        override suspend fun loadKey(deviceId: String): ByteArray? = savedKeys[deviceId]
        override suspend fun deleteKey(deviceId: String) { savedKeys.remove(deviceId) }
        override suspend fun getAllDeviceIds(): List<String> = savedKeys.keys.toList()
    }
}
