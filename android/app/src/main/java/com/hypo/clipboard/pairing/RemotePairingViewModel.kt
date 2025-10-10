package com.hypo.clipboard.pairing

import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.crypto.tink.subtle.X25519
import com.hypo.clipboard.sync.DeviceIdentity
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@HiltViewModel
class RemotePairingViewModel @Inject constructor(
    private val relayClient: PairingRelayClient,
    private val handshakeManager: PairingHandshakeManager,
    private val identity: DeviceIdentity,
    private val json: Json = Json { prettyPrint = true }
) : ViewModel() {
    private val _state = MutableStateFlow(RemotePairingUiState())
    val state: StateFlow<RemotePairingUiState> = _state.asStateFlow()

    private var sessionState: PairingSessionState? = null
    private var countdownJob: Job? = null
    private var pollJob: Job? = null

    fun onCodeChanged(value: String) {
        val digits = value.filter(Char::isDigit).take(6)
        _state.value = _state.value.copy(codeInput = digits, error = null)
    }

    fun submitCode() {
        val code = _state.value.codeInput
        if (code.length != 6) {
            _state.value = _state.value.copy(
                error = "Enter the 6-digit code",
                status = "Enter the 6-digit code from your Mac"
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
                    androidDeviceId = identity.deviceId,
                    androidDeviceName = identity.deviceName,
                    androidPublicKey = Base64.encodeToString(publicKey, Base64.NO_WRAP)
                )
            }.onSuccess { claim ->
                when (val initiation = handshakeManager.initiateRemote(claim, privateKey)) {
                    is PairingInitiationResult.Success -> {
                        sessionState = initiation.state
                        val challengeJson = json.encodeToString(initiation.state.challenge)
                        val submitResult = runCatching {
                            relayClient.submitChallenge(code, identity.deviceId, challengeJson)
                        }
                        if (submitResult.isFailure) {
                            handleRelayFailure(submitResult.exceptionOrNull()!!)
                            return@onSuccess
                        }
                        _state.value = _state.value.copy(
                            phase = RemotePairingPhase.WaitingForAck,
                            status = "Waiting for macOS acknowledgement…",
                            macDeviceName = claim.macDeviceName,
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
        _state.value = RemotePairingUiState()
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
                val remaining = Duration.between(Instant.now(), expiresAt).seconds
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
                    relayClient.pollAck(code, identity.deviceId)
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
                        countdownJob?.cancel()
                        countdownJob = null
                        _state.value = RemotePairingUiState(
                            phase = RemotePairingPhase.Completed,
                            status = "Paired with ${completion.macDeviceName}",
                            codeInput = code,
                            macDeviceName = completion.macDeviceName
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
    val phase: RemotePairingPhase = RemotePairingPhase.EnterCode,
    val status: String = "Enter the 6-digit code from your Mac",
    val codeInput: String = "",
    val macDeviceName: String? = null,
    val error: String? = null,
    val countdownSeconds: Long? = null
)

enum class RemotePairingPhase {
    EnterCode,
    Claiming,
    WaitingForAck,
    Completed,
    Error
}
