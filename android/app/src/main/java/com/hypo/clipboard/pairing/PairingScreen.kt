package com.hypo.clipboard.pairing

import android.Manifest
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

@Composable
fun PairingRoute(
    onBack: () -> Unit,
    qrViewModel: PairingViewModel = hiltViewModel(),
    remoteViewModel: RemotePairingViewModel = hiltViewModel(),
    lanViewModel: LanPairingViewModel = hiltViewModel()
) {
    val qrState by qrViewModel.state.collectAsStateWithLifecycle()
    val remoteState by remoteViewModel.state.collectAsStateWithLifecycle()
    val lanState by lanViewModel.state.collectAsStateWithLifecycle()
    var mode by rememberSaveable { mutableStateOf(PairingMode.AutoDiscovery) }

    LaunchedEffect(mode) {
        when (mode) {
            PairingMode.Qr -> {
                remoteViewModel.reset()
                lanViewModel.reset()
            }
            PairingMode.Remote -> {
                qrViewModel.reset()
                lanViewModel.reset()
            }
            PairingMode.AutoDiscovery -> {
                qrViewModel.reset()
                remoteViewModel.reset()
            }
        }
    }

    PairingScreen(
        mode = mode,
        onModeChange = { mode = it },
        qrState = qrState,
        remoteState = remoteState,
        lanState = lanState,
        onBack = onBack,
        onQrScanned = qrViewModel::onQrDetected,
        onAckSubmitted = qrViewModel::submitAck,
        onQrReset = qrViewModel::reset,
        onRemoteCodeChanged = remoteViewModel::onCodeChanged,
        onRemoteSubmit = remoteViewModel::submitCode,
        onRemoteReset = remoteViewModel::reset,
        onLanDeviceTap = lanViewModel::pairWithDevice,
        onLanReset = lanViewModel::reset
    )
}

@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class)
@Composable
fun PairingScreen(
    mode: PairingMode,
    onModeChange: (PairingMode) -> Unit,
    qrState: PairingUiState,
    remoteState: RemotePairingUiState,
    lanState: LanPairingUiState,
    onBack: () -> Unit,
    onQrScanned: (String) -> Unit,
    onAckSubmitted: (String) -> Unit,
    onQrReset: () -> Unit,
    onRemoteCodeChanged: (String) -> Unit,
    onRemoteSubmit: () -> Unit,
    onRemoteReset: () -> Unit,
    onLanDeviceTap: (com.hypo.clipboard.transport.lan.DiscoveredPeer) -> Unit,
    onLanReset: () -> Unit,
    modifier: Modifier = Modifier
) {
    val cameraPermissionState = rememberPermissionState(Manifest.permission.CAMERA)

    LaunchedEffect(Unit) {
        if (!cameraPermissionState.status.isGranted) {
            cameraPermissionState.launchPermissionRequest()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(text = "Pair Device") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(imageVector = Icons.Filled.ArrowBack, contentDescription = null)
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
            ModeToggle(mode = mode, onModeChange = onModeChange)

            when (mode) {
                PairingMode.AutoDiscovery -> {
                    AutoDiscoveryContent(
                        state = lanState,
                        onDeviceTap = onLanDeviceTap,
                        onReset = onLanReset
                    )
                }
                PairingMode.Qr -> {
                    Text(text = qrState.status, style = MaterialTheme.typography.titleMedium)
                    when (qrState.phase) {
                        PairingPhase.Scanning, PairingPhase.Processing -> {
                            if (cameraPermissionState.status.isGranted) {
                                BarcodeScannerView(onQrScanned = onQrScanned)
                            } else {
                                PermissionRequiredView(onRequest = cameraPermissionState::launchPermissionRequest)
                            }
                        }
                        PairingPhase.ChallengeReady -> {
                            ChallengeView(state = qrState, onAckSubmitted = onAckSubmitted)
                        }
                        PairingPhase.AwaitingAck -> {
                            Text(text = "Waiting for acknowledgement…", style = MaterialTheme.typography.bodyLarge)
                        }
                        PairingPhase.Completed -> {
                            SuccessView(onReset = onQrReset)
                        }
                        PairingPhase.Error -> {
                            ErrorView(message = qrState.error ?: "Unknown error", onReset = onQrReset)
                        }
                    }
                }
                PairingMode.Remote -> {
                    RemotePairingView(
                        state = remoteState,
                        onCodeChanged = onRemoteCodeChanged,
                        onSubmit = onRemoteSubmit,
                        onReset = onRemoteReset
                    )
                }
            }
        }
    }
}

enum class PairingMode { Qr, Remote, AutoDiscovery }

@Composable
private fun ModeToggle(mode: PairingMode, onModeChange: (PairingMode) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ModeButton(
            label = "LAN",
            selected = mode == PairingMode.AutoDiscovery,
            onClick = { onModeChange(PairingMode.AutoDiscovery) }
        )
        ModeButton(
            label = "QR",
            selected = mode == PairingMode.Qr,
            onClick = { onModeChange(PairingMode.Qr) }
        )
        ModeButton(
            label = "Code",
            selected = mode == PairingMode.Remote,
            onClick = { onModeChange(PairingMode.Remote) }
        )
    }
}

@Composable
private fun ModeButton(label: String, selected: Boolean, onClick: () -> Unit) {
    if (selected) {
        Button(onClick = onClick) { Text(text = label) }
    } else {
        OutlinedButton(onClick = onClick) { Text(text = label) }
    }
}

@Composable
private fun BarcodeScannerView(onQrScanned: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewViewState = remember { mutableStateOf<PreviewView?>(null) }
    val hasProcessed = remember { mutableStateOf(false) }

    AndroidView(factory = { ctx ->
        val previewView = PreviewView(ctx)
        previewViewState.value = previewView
        val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = androidx.camera.core.Preview.Builder()
                .build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val analysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            val scanner = BarcodeScanning.getClient(
                BarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                    .build()
            )
            val executor = Executors.newSingleThreadExecutor()
            analysis.setAnalyzer(executor) { imageProxy ->
                processFrame(scanner, imageProxy, hasProcessed, onQrScanned)
            }
            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                analysis
            )
        }, ContextCompat.getMainExecutor(ctx))
        previewView
    }, modifier = Modifier
        .fillMaxWidth()
        .height(320.dp)
        .background(Color.Black))
}

private fun processFrame(
    scanner: com.google.mlkit.vision.barcode.BarcodeScanner,
    imageProxy: ImageProxy,
    hasProcessed: MutableState<Boolean>,
    onQrScanned: (String) -> Unit
) {
    if (hasProcessed.value) {
        imageProxy.close()
        return
    }
    val mediaImage = imageProxy.image
    if (mediaImage != null) {
        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        scanner.process(image)
            .addOnSuccessListener { barcodes ->
                val qr = barcodes.firstOrNull { it.valueType == Barcode.TYPE_TEXT || it.rawValue != null }
                val value = qr?.rawValue
                if (value != null) {
                    hasProcessed.value = true
                    onQrScanned(value)
                }
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    } else {
        imageProxy.close()
    }
}

@Composable
private fun PermissionRequiredView(onRequest: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(imageVector = Icons.Filled.Error, contentDescription = null, tint = MaterialTheme.colorScheme.error)
        Text(text = "Camera permission is required to scan QR codes.")
        Button(onClick = onRequest) { Text(text = "Grant Permission") }
    }
}

@Composable
private fun ChallengeView(state: PairingUiState, onAckSubmitted: (String) -> Unit) {
    val scrollState = rememberScrollState()
    val ackInput = remember { mutableStateOf("") }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(text = "Challenge JSON", style = MaterialTheme.typography.labelLarge)
        OutlinedTextField(
            value = state.challengeJson.orEmpty(),
            onValueChange = {},
            modifier = Modifier
                .fillMaxWidth()
                .height(200.dp),
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            readOnly = true
        )
        state.relayHint?.let { hint ->
            Text(text = "Relay hint: $hint", style = MaterialTheme.typography.bodySmall)
        }
        Spacer(modifier = Modifier.height(8.dp))
        Text(text = "Paste acknowledgement JSON when macOS responds", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = ackInput.value,
            onValueChange = { ackInput.value = it },
            modifier = Modifier
                .fillMaxWidth()
                .height(160.dp),
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
        )
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Button(onClick = { onAckSubmitted(ackInput.value) }, enabled = ackInput.value.isNotBlank()) {
                Text(text = "Submit Ack")
            }
        }
    }
}

@Composable
private fun RemotePairingView(
    state: RemotePairingUiState,
    onCodeChanged: (String) -> Unit,
    onSubmit: () -> Unit,
    onReset: () -> Unit
) {
    when (state.phase) {
        RemotePairingPhase.Completed -> {
            RemoteSuccessView(deviceName = state.macDeviceName, onReset = onReset)
        }
        RemotePairingPhase.Error -> {
            ErrorView(message = state.error ?: "Pairing failed", onReset = onReset)
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
                        Text(text = "Completing secure handshake…", style = MaterialTheme.typography.bodyMedium)
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
private fun SuccessView(onReset: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(imageVector = Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Text(text = "Pairing successful", style = MaterialTheme.typography.titleMedium)
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

@Composable
private fun AutoDiscoveryContent(
    state: LanPairingUiState,
    onDeviceTap: (com.hypo.clipboard.transport.lan.DiscoveredPeer) -> Unit,
    onReset: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            text = "Nearby Devices",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(bottom = 8.dp)
        )
        
        when (state) {
            is LanPairingUiState.Discovering -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    CircularProgressIndicator()
                    Text(
                        text = "Searching for macOS devices...",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Text(
                        text = "Make sure your macOS device is on the same network",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            
            is LanPairingUiState.DevicesFound -> {
                if (state.devices.isEmpty()) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Error,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = MaterialTheme.colorScheme.error
                        )
                        Text(
                            text = "No devices found",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Make sure your macOS device is running Hypo",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        OutlinedButton(onClick = onReset) {
                            Text(text = "Retry")
                        }
                    }
                } else {
                    state.devices.forEach { device ->
                        DeviceCard(
                            device = device,
                            onClick = { onDeviceTap(device) }
                        )
                    }
                }
            }
            
            is LanPairingUiState.Pairing -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    CircularProgressIndicator()
                    Text(
                        text = "Pairing with ${state.deviceName}...",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = "Please wait",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            
            is LanPairingUiState.Success -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.CheckCircle,
                        contentDescription = null,
                        modifier = Modifier.size(64.dp),
                        tint = Color(0xFF4CAF50)
                    )
                    Text(
                        text = "Paired Successfully!",
                        style = MaterialTheme.typography.titleLarge
                    )
                    Text(
                        text = "Connected to ${state.deviceName}",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    OutlinedButton(onClick = onReset) {
                        Text(text = "Pair another device")
                    }
                }
            }
            
            is LanPairingUiState.Error -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Error,
                        contentDescription = null,
                        modifier = Modifier.size(48.dp),
                        tint = MaterialTheme.colorScheme.error
                    )
                    Text(
                        text = "Pairing Failed",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = state.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                    OutlinedButton(onClick = onReset) {
                        Text(text = "Try Again")
                    }
                }
            }
        }
    }
}

@Composable
private fun DeviceCard(
    device: com.hypo.clipboard.transport.lan.DiscoveredPeer,
    onClick: () -> Unit
) {
    androidx.compose.material3.Card(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = device.serviceName,
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "${device.host}:${device.port}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (device.fingerprint != null) {
                    Text(
                        text = "🔒 Secured",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF4CAF50)
                    )
                }
            }
            Icon(
                imageVector = Icons.Filled.ArrowBack,
                contentDescription = "Pair",
                modifier = Modifier.size(24.dp)
            )
        }
    }
}
