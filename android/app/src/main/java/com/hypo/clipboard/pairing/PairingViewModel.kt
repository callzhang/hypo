package com.hypo.clipboard.pairing

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@HiltViewModel
class PairingViewModel @Inject constructor(
    private val handshakeManager: PairingHandshakeManager,
    private val json: Json = Json { prettyPrint = true }
) : ViewModel() {
    private val _state = MutableStateFlow(PairingUiState())
    val state: StateFlow<PairingUiState> = _state.asStateFlow()

    private var sessionState: PairingSessionState? = null

    fun onQrDetected(content: String) {
        _state.value = _state.value.copy(phase = PairingPhase.Processing, status = "Validating QR…")
        viewModelScope.launch {
            when (val result = handshakeManager.initiate(content)) {
                is PairingInitiationResult.Success -> {
                    sessionState = result.state
                    val challengeJson = json.encodeToString(result.state.challenge)
                    _state.value = PairingUiState(
                        phase = PairingPhase.ChallengeReady,
                        status = "Challenge generated. Waiting for macOS acknowledgement…",
                        challengeJson = challengeJson,
                        macDeviceId = result.state.payload.macDeviceId,
                        relayHint = result.state.payload.relayHint
                    )
                }
                is PairingInitiationResult.Failure -> {
                    sessionState = null
                    _state.value = PairingUiState(
                        phase = PairingPhase.Error,
                        status = result.reason,
                        error = result.reason
                    )
                }
            }
        }
    }

    fun submitAck(ackJson: String) {
        val stateSnapshot = sessionState ?: run {
            _state.value = _state.value.copy(
                phase = PairingPhase.Error,
                status = "No active pairing session",
                error = "No active pairing session"
            )
            return
        }
        _state.value = _state.value.copy(phase = PairingPhase.AwaitingAck, status = "Validating acknowledgement…")
        viewModelScope.launch {
            when (val result = handshakeManager.complete(stateSnapshot, ackJson)) {
                is PairingCompletionResult.Success -> {
                    _state.value = PairingUiState(
                        phase = PairingPhase.Completed,
                        status = "Paired with ${result.macDeviceName}",
                        macDeviceId = result.macDeviceId
                    )
                    sessionState = null
                }
                is PairingCompletionResult.Failure -> {
                    _state.value = PairingUiState(
                        phase = PairingPhase.Error,
                        status = result.reason,
                        error = result.reason
                    )
                }
            }
        }
    }

    fun reset() {
        sessionState = null
        _state.value = PairingUiState()
    }
}

data class PairingUiState(
    val phase: PairingPhase = PairingPhase.Scanning,
    val status: String = "Align QR code within the frame",
    val challengeJson: String? = null,
    val macDeviceId: String? = null,
    val relayHint: String? = null,
    val error: String? = null
)

enum class PairingPhase {
    Scanning,
    Processing,
    ChallengeReady,
    AwaitingAck,
    Completed,
    Error
}
