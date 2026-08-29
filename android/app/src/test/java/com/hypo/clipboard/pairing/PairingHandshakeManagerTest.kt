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


    @Test
    fun `handleChallenge returns the initiator identity so its name can be persisted`() = runTest {
        // Regression guard. The responder path had no test at all, which is how
        // it shipped storing a shared key without ever recording who it belonged
        // to. ConnectionStatusProber then deleted that key as an orphan, and the
        // phone silently un-paired every device that initiated pairing to it.
        val initiatorDeviceId = "550e8400-e29b-41d4-a716-446655440000"
        val initiatorDeviceName = "Derek's Windows PC"

        val initiatorPrivate = X25519.generatePrivateKey()
        val initiatorPublic = X25519.publicFromPrivate(initiatorPrivate)
        val responderPrivate = X25519.generatePrivateKey()
        val responderPublic = X25519.publicFromPrivate(responderPrivate)

        val crypto = CryptoService()
        val sharedKey = crypto.deriveKey(initiatorPrivate, responderPublic)

        val challengeSecret = ByteArray(32) { it.toByte() }
        val challengePayload = PairingChallengePayload(
            challenge = Base64.getEncoder().encodeToString(challengeSecret),
            timestamp = clock.instant().toString()
        )
        val sealed = crypto.encrypt(
            plaintext = json.encodeToString(challengePayload).toByteArray(),
            key = sharedKey,
            aad = initiatorDeviceId.toByteArray()
        )
        val challenge = PairingChallengeMessage(
            initiatorDeviceId = initiatorDeviceId,
            initiatorDeviceName = initiatorDeviceName,
            initiatorPublicKey = Base64.getEncoder().encodeToString(initiatorPublic),
            nonce = Base64.getEncoder().encodeToString(sealed.nonce),
            ciphertext = Base64.getEncoder().encodeToString(sealed.ciphertext),
            tag = Base64.getEncoder().encodeToString(sealed.tag)
        )

        val manager = PairingHandshakeManager(
            cryptoService = crypto,
            deviceKeyStore = keyStore,
            trustStore = trustStore,
            identity = identity,
            clock = clock,
            json = json
        )

        val handled = manager.handleChallenge(json.encodeToString(challenge), responderPrivate)

        assertTrue("handleChallenge should succeed", handled != null)
        handled!!

        // The key is stored...
        assertTrue(keyStore.savedKeys.containsKey(initiatorDeviceId))

        // ...and the identity needed to keep it comes back with the ack, so the
        // caller cannot store a key without also being handed the name.
        assertEquals(initiatorDeviceId, handled.peerDeviceId)
        assertEquals(initiatorDeviceName, handled.peerDeviceName)
        assertTrue("ack should be JSON", handled.ackJson.startsWith("{"))
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
