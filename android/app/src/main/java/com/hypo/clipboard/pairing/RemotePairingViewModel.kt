package com.hypo.clipboard.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.crypto.tink.subtle.X25519
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.ActiveTransport
import com.hypo.clipboard.transport.TransportManager
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@HiltViewModel
class RemotePairingViewModel @Inject constructor(
    private val relayClient: PairingRelayClient,
    private val handshakeManager: PairingHandshakeManager,
    private val identity: DeviceIdentity,
    private val transportManager: TransportManager,
    private val syncCoordinator: SyncCoordinator,
    private val clock: Clock = Clock.systemUTC(),
    private val json: Json = Json { prettyPrint = true }
) : ViewModel() {
    private val _state = MutableStateFlow(RemotePairingUiState(phase = RemotePairingPhase.Idle, status = "Choose an option"))
    val state: StateFlow<RemotePairingUiState> = _state.asStateFlow()

    private var sessionState: PairingSessionState? = null
    private var countdownJob: Job? = null
    private var pollJob: Job? = null

    fun generateCode() {
        if (_state.value.phase == RemotePairingPhase.GeneratingCode || _state.value.phase == RemotePairingPhase.DisplayingCode || _state.value.phase == RemotePairingPhase.WaitingForAck) {
            return
        }
        _state.value = _state.value.copy(
            phase = RemotePairingPhase.GeneratingCode,
            status = "Generating pairing code…",
            error = null
        )
        viewModelScope.launch {
            runCatching {
                val privateKey = X25519.generatePrivateKey()
                val publicKey = X25519.publicFromPrivate(privateKey)
                val publicKeyBase64 = Base64.encodeToString(publicKey, Base64.NO_WRAP)
                android.util.Log.d("RemotePairingViewModel", "🔵 Creating pairing code...")
                val pairingCode = relayClient.createPairingCode(
                    initiatorDeviceId = identity.deviceId,
                    initiatorDeviceName = identity.deviceName,
                    initiatorPublicKey = publicKeyBase64
                )
                android.util.Log.d("RemotePairingViewModel", "✅ Pairing code created: ${pairingCode.code}, expires at ${pairingCode.expiresAt}")
                
                // Create a payload for the session state (similar to macOS)
                val payload = PairingPayload(
                    version = "1",
                    peerDeviceId = identity.deviceId, // Will be updated when responder claims
                    peerPublicKey = publicKeyBase64,
                    peerSigningPublicKey = "", // Not used for cloud pairing
                    service = "",
                    port = 0,
                    relayHint = null,
                    issuedAt = clock.instant().toString(),
                    expiresAt = pairingCode.expiresAt.toString(),
                    signature = ""
                )
                
                // Create session state for handling challenge
                sessionState = PairingSessionState(
                    payload = payload,
                    androidPrivateKey = privateKey,
                    sharedKey = ByteArray(32), // Will be derived when responder claims
                    challengeSecret = ByteArray(32), // Not used when we're initiator
                    challenge = PairingChallengeMessage(
                        challengeId = "",
                        initiatorDeviceId = identity.deviceId,
                        initiatorDeviceName = identity.deviceName,
                        initiatorPublicKey = publicKeyBase64,
                        nonce = "",
                        ciphertext = "",
                        tag = ""
                    )
                )
                
                _state.value = _state.value.copy(
                    phase = RemotePairingPhase.DisplayingCode,
                    status = "Share this code with the other device",
                    generatedCode = pairingCode.code,
                    error = null
                )
                startCountdown(pairingCode.expiresAt)
                beginPollingChallenge(pairingCode.code, identity.deviceId)
            }.onFailure { throwable ->
                handleRelayFailure(throwable)
            }
        }
    }
    
    private fun beginPollingChallenge(code: String, initiatorDeviceId: String) {
        pollJob?.cancel()
        // Keep DisplayingCode phase but update status (mirror macOS: .awaitingChallenge still shows code)
        _state.value = _state.value.copy(
            phase = RemotePairingPhase.DisplayingCode,
            status = "Waiting for peer device…",
            generatedCode = code // Ensure code is still visible
        )
        android.util.Log.d("RemotePairingViewModel", "🔵 beginPollingChallenge: code=$code, initiatorDeviceId=$initiatorDeviceId")
        pollJob = viewModelScope.launch {
            var pollCount = 0
            while (true) {
                pollCount++
                android.util.Log.d("RemotePairingViewModel", "🔵 Polling for challenge (attempt #$pollCount)...")
                val challengeJson = try {
                    val result = relayClient.pollChallenge(code, initiatorDeviceId)
                    android.util.Log.d("RemotePairingViewModel", "✅ Received challenge (${result.length} chars)")
                    result
                } catch (error: PairingRelayException.ChallengeNotReady) {
                    android.util.Log.d("RemotePairingViewModel", "⏳ Challenge not ready yet, retrying in 1.5s...")
                    delay(1_500)
                    continue
                } catch (error: Throwable) {
                    android.util.Log.e("RemotePairingViewModel", "❌ Error polling challenge: ${error.message}", error)
                    handleRelayFailure(error)
                    return@launch
                }
                
                val stateSnapshot = sessionState ?: run {
                    handleRelayFailure(IllegalStateException("No active pairing session"))
                    return@launch
                }
                
                // Decode challenge message (mirror macOS flow)
                android.util.Log.d("RemotePairingViewModel", "🔵 Decoding challenge message...")
                val challenge = json.decodeFromString<PairingChallengeMessage>(challengeJson)
                
                // Update status to "Processing challenge…" (mirror macOS: state = .completing)
                _state.value = _state.value.copy(
                    phase = RemotePairingPhase.WaitingForAck,
                    status = "Processing challenge…"
                )
                
                // Handle challenge and generate ACK (mirror macOS: session.handleChallenge)
                android.util.Log.d("RemotePairingViewModel", "🔵 Handling challenge and generating ACK...")
                val ackJson = handshakeManager.handleChallengeAsInitiator(challengeJson, stateSnapshot)
                if (ackJson == null) {
                    android.util.Log.e("RemotePairingViewModel", "❌ Failed to handle challenge - returned null")
                    handleRelayFailure(IllegalStateException("Failed to handle challenge"))
                    return@launch
                }
                android.util.Log.d("RemotePairingViewModel", "✅ Generated ACK (${ackJson.length} chars)")
                
                // Complete pairing (mirror macOS: delegate.didCompleteWith is called inside handleChallenge)
                // When we're the initiator, the challenge comes from the responder
                // The challenge.initiatorDeviceId is actually the responder's device ID
                val migratedDeviceId = challenge.initiatorDeviceId
                val deviceName = challenge.initiatorDeviceName
                
                android.util.Log.d("RemotePairingViewModel", "✅ Pairing handshake completed! Key saved for device: $migratedDeviceId")
                
                // Cloud-paired devices should always be marked with CLOUD transport
                // This ensures they show as available via cloud even if also on LAN
                transportManager.markDeviceConnected(migratedDeviceId, ActiveTransport.CLOUD)
                android.util.Log.d("RemotePairingViewModel", "Cloud-paired device marked as CLOUD transport")
                
                // Also mark as LAN if discovered (allows dual transport: LAN + Cloud)
                val peers = transportManager.currentPeers()
                val isDiscoveredOnLan = peers.any {
                    val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                    peerDeviceId == migratedDeviceId || peerDeviceId.equals(migratedDeviceId, ignoreCase = true)
                }
                if (isDiscoveredOnLan) {
                    // Note: markDeviceConnected will update the transport, but CLOUD is already set
                    // The last successful transport will be used, but both are available
                    android.util.Log.d("RemotePairingViewModel", "Device also discovered on LAN (dual transport: LAN + Cloud)")
                }
                
                transportManager.persistDeviceName(migratedDeviceId, deviceName)
                syncCoordinator.addTargetDevice(migratedDeviceId)
                
                // Update UI state to completed (mirror macOS: delegate updates state)
                countdownJob?.cancel()
                countdownJob = null
                _state.value = RemotePairingUiState(
                    phase = RemotePairingPhase.Completed,
                    status = "Paired with $deviceName",
                    codeInput = code,
                    macDeviceName = deviceName
                )
                
                // Submit ACK (mirror macOS: submit ACK after completion)
                android.util.Log.d("RemotePairingViewModel", "🔵 Submitting ACK to relay...")
                try {
                    relayClient.submitAck(code, initiatorDeviceId, ackJson)
                    android.util.Log.d("RemotePairingViewModel", "✅ ACK submitted successfully")
                } catch (error: Throwable) {
                    android.util.Log.e("RemotePairingViewModel", "❌ Failed to submit ACK: ${error.message}", error)
                    // Note: Pairing is already completed, so we don't fail here
                    // The ACK submission failure is logged but doesn't affect pairing completion
                }
                
                // Exit polling loop (mirror macOS: return after submitting ACK)
                pollJob = null
                sessionState = null
                return@launch
            }
        }
    }

    fun onCodeChanged(value: String) {
        val digits = value.filter(Char::isDigit).take(6)
        _state.value = _state.value.copy(codeInput = digits, error = null)
    }

    fun submitCode() {
        val code = _state.value.codeInput
        if (code.length != 6) {
            _state.value = _state.value.copy(
                error = "Enter the 6-digit code",
                status = "Enter the 6-digit code from the other device"
            )
            return
        }
        if (_state.value.phase == RemotePairingPhase.Claiming || _state.value.phase == RemotePairingPhase.WaitingForAck) {
            return
        }
        val privateKey = X25519.generatePrivateKey()
        val publicKey = X25519.publicFromPrivate(privateKey)
        _state.value = _state.value.copy(
            phase = RemotePairingPhase.Claiming,
            status = "Claiming pairing code…",
            error = null
        )
        viewModelScope.launch {
            runCatching {
                relayClient.claimPairingCode(
                    code = code,
                    responderDeviceId = identity.deviceId,
                    responderDeviceName = identity.deviceName,
                    responderPublicKey = Base64.encodeToString(publicKey, Base64.NO_WRAP)
                )
            }.onSuccess { claim ->
                when (val initiation = handshakeManager.initiateRemote(claim, privateKey)) {
                    is PairingInitiationResult.Success -> {
                        sessionState = initiation.state
                        val challengeJson = json.encodeToString(initiation.state.challenge)
                        val submitResult = runCatching {
                            relayClient.submitChallenge(code, identity.deviceId, challengeJson) // responderDeviceId
                        }
                        if (submitResult.isFailure) {
                            handleRelayFailure(submitResult.exceptionOrNull()!!)
                            return@onSuccess
                        }
                        _state.value = _state.value.copy(
                            phase = RemotePairingPhase.WaitingForAck,
                            status = "Waiting for peer device acknowledgement…",
                            macDeviceName = claim.initiatorDeviceName,
                            error = null
                        )
                        startCountdown(claim.expiresAt)
                        startPollingAck(code)
                    }
                    is PairingInitiationResult.Failure -> {
                        _state.value = RemotePairingUiState(
                            phase = RemotePairingPhase.Error,
                            status = initiation.reason,
                            codeInput = code,
                            error = initiation.reason
                        )
                    }
                }
            }.onFailure { throwable ->
                handleRelayFailure(throwable)
            }
        }
    }

    fun reset() {
        countdownJob?.cancel()
        countdownJob = null
        pollJob?.cancel()
        pollJob = null
        sessionState = null
        _state.value = RemotePairingUiState(phase = RemotePairingPhase.Idle, status = "Choose an option")
    }

    fun switchToEnterCode() {
        _state.value = _state.value.copy(
            phase = RemotePairingPhase.EnterCode,
            status = "Enter the 6-digit code from the other device",
            error = null
        )
    }

    private fun handleRelayFailure(throwable: Throwable) {
        val message = when (throwable) {
            is PairingRelayException.CodeNotFound -> "Pairing code not found"
            is PairingRelayException.CodeExpired -> "Pairing code expired"
            is PairingRelayException.CodeAlreadyClaimed -> "Pairing code already claimed"
            is PairingRelayException.Server -> throwable.errorMessage
            is PairingRelayException.Network -> "Network error: ${throwable.message ?: "unknown"}"
            else -> throwable.message ?: "Pairing failed"
        }
        _state.value = _state.value.copy(
            phase = RemotePairingPhase.Error,
            status = message,
            error = message
        )
        countdownJob?.cancel()
        countdownJob = null
        pollJob?.cancel()
        pollJob = null
    }

    private fun startCountdown(expiresAt: Instant) {
        countdownJob?.cancel()
        countdownJob = viewModelScope.launch {
            while (true) {
                val remaining = Duration.between(clock.instant(), expiresAt).seconds
                if (remaining <= 0) {
                    _state.value = _state.value.copy(
                        countdownSeconds = null,
                        phase = RemotePairingPhase.Error,
                        status = "Pairing code expired",
                        error = "Pairing code expired"
                    )
                    pollJob?.cancel()
                    pollJob = null
                    break
                } else {
                    _state.value = _state.value.copy(countdownSeconds = remaining)
                }
                delay(1_000)
            }
        }
    }

    private fun startPollingAck(code: String) {
        pollJob?.cancel()
        pollJob = viewModelScope.launch {
            while (true) {
                val ackJson = try {
                    relayClient.pollAck(code, identity.deviceId) // responderDeviceId
                } catch (error: PairingRelayException.AckNotReady) {
                    delay(1_500)
                    continue
                } catch (error: Throwable) {
                    handleRelayFailure(error)
                    return@launch
                }
                val stateSnapshot = sessionState ?: run {
                    handleRelayFailure(IllegalStateException("No active pairing session"))
                    return@launch
                }
                when (val completion = handshakeManager.complete(stateSnapshot, ackJson)) {
                    is PairingCompletionResult.Success -> {
                        // Migrate device ID from old format (with prefix) to new format (pure UUID)
                        val deviceId = completion.peerDeviceId
                        val deviceName = completion.peerDeviceName
                        
                        android.util.Log.d("RemotePairingViewModel", "✅ Pairing handshake completed! Key saved for device: $deviceId")
                        
                        // Cloud-paired devices should always be marked with CLOUD transport
                        // This ensures they show as available via cloud even if also on LAN
                        transportManager.markDeviceConnected(deviceId, ActiveTransport.CLOUD)
                        android.util.Log.d("RemotePairingViewModel", "Cloud-paired device marked as CLOUD transport")
                        
                        // Also check if device is discoverable on LAN (allows dual transport: LAN + Cloud)
                        val peers = transportManager.currentPeers()
                        val isDiscoveredOnLan = peers.any {
                            val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                            peerDeviceId == deviceId || peerDeviceId.equals(deviceId, ignoreCase = true)
                        }
                        if (isDiscoveredOnLan) {
                            android.util.Log.d("RemotePairingViewModel", "Device also discovered on LAN (dual transport: LAN + Cloud)")
                        }
                        
                        // Store device name for display when device is offline
                        transportManager.persistDeviceName(deviceId, deviceName)
                        
                        android.util.Log.d("RemotePairingViewModel", "Paired device $deviceId, name=$deviceName, discoveredOnLan=$isDiscoveredOnLan")
                        
                        // Register device as sync target
                        android.util.Log.d("RemotePairingViewModel", "🎯 Registering device as manual sync target...")
                        syncCoordinator.addTargetDevice(deviceId)
                        val targets = syncCoordinator.targets.value
                        android.util.Log.d("RemotePairingViewModel", "✅ Target devices now: $targets (count: ${targets.size})")
                        
                        countdownJob?.cancel()
                        countdownJob = null
                        _state.value = RemotePairingUiState(
                            phase = RemotePairingPhase.Completed,
                            status = "Paired with $deviceName",
                            codeInput = code,
                            macDeviceName = deviceName
                        )
                        pollJob = null
                        sessionState = null
                        return@launch
                    }
                    is PairingCompletionResult.Failure -> {
                        _state.value = _state.value.copy(
                            phase = RemotePairingPhase.Error,
                            status = completion.reason,
                            error = completion.reason
                        )
                        pollJob = null
                        sessionState = null
                        return@launch
                    }
                }
            }
        }
    }
}

data class RemotePairingUiState(
    val phase: RemotePairingPhase = RemotePairingPhase.Idle,
    val status: String = "",
    val codeInput: String = "",
    val generatedCode: String? = null,
    val macDeviceName: String? = null,
    val error: String? = null,
    val countdownSeconds: Long? = null
)

enum class RemotePairingPhase {
    Idle,
    GeneratingCode,
    DisplayingCode,
    EnterCode,
    Claiming,
    WaitingForAck,
    Completed,
    Error
}
