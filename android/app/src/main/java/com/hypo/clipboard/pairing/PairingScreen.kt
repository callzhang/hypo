package com.hypo.clipboard.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hypo.clipboard.R

@Composable
fun PairingRoute(
    onBack: () -> Unit,
    remoteViewModel: RemotePairingViewModel = hiltViewModel()
) {
    val remoteState by remoteViewModel.state.collectAsStateWithLifecycle()

    PairingScreen(
        remoteState = remoteState,
        onBack = onBack,
        onRemoteCodeChanged = remoteViewModel::onCodeChanged,
        onRemoteSubmit = remoteViewModel::submitCode,
        onRemoteReset = remoteViewModel::reset,
        onRemoteGenerateCode = { remoteViewModel.generateCode() },
        onRemoteSwitchToEnterCode = { remoteViewModel.switchToEnterCode() }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingScreen(
    remoteState: RemotePairingUiState,
    onBack: () -> Unit,
    onRemoteCodeChanged: (String) -> Unit,
    onRemoteSubmit: () -> Unit,
    onRemoteReset: () -> Unit,
    onRemoteGenerateCode: () -> Unit,
    onRemoteSwitchToEnterCode: () -> Unit,
    modifier: Modifier = Modifier
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(text = stringResource(id = R.string.pairing_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(imageVector = Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            RemotePairingView(
                state = remoteState,
                onCodeChanged = onRemoteCodeChanged,
                onSubmit = onRemoteSubmit,
                onReset = onRemoteReset,
                onGenerateCode = onRemoteGenerateCode,
                onSwitchToEnterCode = onRemoteSwitchToEnterCode
            )
        }
    }
}

@Composable
private fun RemotePairingView(
    state: RemotePairingUiState,
    onCodeChanged: (String) -> Unit,
    onSubmit: () -> Unit,
    onReset: () -> Unit,
    onGenerateCode: () -> Unit,
    onSwitchToEnterCode: () -> Unit
) {
    when (state.phase) {
        RemotePairingPhase.Completed -> {
            RemoteSuccessView(deviceName = state.macDeviceName, onReset = onReset)
        }
        RemotePairingPhase.Error -> {
            ErrorView(message = state.error ?: "Pairing failed", onReset = onReset)
        }
        RemotePairingPhase.Idle -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "Cloud Pairing",
                    style = MaterialTheme.typography.titleLarge
                )
                Text(
                    text = "Choose how you want to pair",
                    style = MaterialTheme.typography.bodyMedium
                )
                Button(
                    onClick = onGenerateCode,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(text = "Generate Code")
                }
                Text(
                    text = "OR",
                    style = MaterialTheme.typography.bodyMedium
                )
                Button(
                    onClick = onSwitchToEnterCode,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(text = "Enter Code")
                }
            }
        }
        RemotePairingPhase.GeneratingCode -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                CircularProgressIndicator()
                Text(text = state.status, style = MaterialTheme.typography.bodyMedium)
            }
        }
        RemotePairingPhase.DisplayingCode -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = state.status,
                    style = MaterialTheme.typography.titleMedium
                )
                state.generatedCode?.let { code ->
                    Text(
                        text = code,
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(vertical = 16.dp)
                    )
                }
                state.countdownSeconds?.let { seconds ->
                    Text(
                        text = "Expires in ${seconds}s",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Text(
                    text = "Waiting for peer device to enter this code...",
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
        else -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Text(text = state.status, style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = state.codeInput,
                    onValueChange = onCodeChanged,
                    label = { Text(text = "Pairing code") },
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    enabled = state.phase == RemotePairingPhase.EnterCode
                )
                state.countdownSeconds?.let { seconds ->
                    Text(
                        text = "Expires in ${seconds}s",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    Button(
                        onClick = onSubmit,
                        enabled = state.codeInput.length == 6 && state.phase == RemotePairingPhase.EnterCode
                    ) {
                        Text(text = "Submit code")
                    }
                }
                if (state.phase == RemotePairingPhase.Claiming || state.phase == RemotePairingPhase.WaitingForAck) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                        Text(text = state.status, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun RemoteSuccessView(deviceName: String?, onReset: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(imageVector = Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Text(
            text = deviceName?.let { "Paired with $it" } ?: "Pairing successful",
            style = MaterialTheme.typography.titleMedium
        )
        OutlinedButton(onClick = onReset) { Text(text = "Pair another device") }
    }
}

@Composable
private fun ErrorView(message: String, onReset: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(imageVector = Icons.Filled.Error, contentDescription = null, tint = MaterialTheme.colorScheme.error)
        Text(text = message, style = MaterialTheme.typography.bodyLarge)
        OutlinedButton(onClick = onReset) { Text(text = "Try again") }
    }
}
