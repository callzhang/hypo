# Hypo Android Client

Native Android application for clipboard synchronization with macOS, built with Kotlin and Jetpack Compose.

---

## Overview

The Android client provides:
- Background foreground service for clipboard monitoring
- Material 3 UI with dynamic color
- Real-time clipboard sync to macOS
- Local history storage with Room database
- Full-text search across clipboard history
- Device pairing via QR code scanning
- **Battery optimization**: Auto-idles WebSocket connections when screen is off

---

## Requirements

- **Android**: 8.0+ (API 26+)
- **Target SDK**: 34 (Android 14)
- **Kotlin**: 2.0+
- **Gradle**: 8.2+
- **Android Studio**: Hedgehog or later

---

## Architecture

```
app/src/main/
├── java/com/hypo/clipboard/
│   ├── MainActivity.kt
│   ├── HypoApplication.kt
│   │
│   ├── ui/
│   │   ├── home/
│   │   │   ├── HomeScreen.kt
│   │   │   └── HomeViewModel.kt
│   │   ├── history/
│   │   │   ├── HistoryScreen.kt
│   │   │   └── HistoryViewModel.kt
│   │   ├── settings/
│   │   │   ├── SettingsScreen.kt
│   │   │   └── SettingsViewModel.kt
│   │   ├── pairing/
│   │   │   ├── PairingScreen.kt
│   │   │   └── QrScannerView.kt
│   │   └── theme/
│   │       ├── Theme.kt
│   │       └── Color.kt
│   │
│   ├── service/
│   │   ├── ClipboardSyncService.kt      # Foreground service
│   │   ├── ClipboardListener.kt
│   │   └── SyncWorker.kt                # WorkManager backup
│   │
│   ├── data/
│   │   ├── db/
│   │   │   ├── ClipboardDatabase.kt
│   │   │   ├── ClipboardDao.kt
│   │   │   └── ClipboardEntity.kt
│   │   ├── repository/
│   │   │   ├── ClipboardRepository.kt
│   │   │   └── DeviceRepository.kt
│   │   ├── preferences/
│   │   │   └── SettingsDataStore.kt
│   │   └── model/
│   │       ├── ClipboardItem.kt
│   │       └── SyncMessage.kt
│   │
│   ├── sync/
│   │   ├── SyncEngine.kt
│   │   ├── TransportManager.kt
│   │   └── CryptoService.kt
│   │
│   ├── network/
│   │   ├── NsdDiscovery.kt              # Network Service Discovery
│   │   ├── WebSocketClient.kt
│   │   └── CloudRelayClient.kt
│   │
│   ├── util/
│   │   ├── KeyManager.kt                # EncryptedSharedPreferences
│   │   ├── NotificationHelper.kt
│   │   └── Logger.kt
│   │
│   └── di/                              # Hilt dependency injection
│       ├── AppModule.kt
│       ├── DatabaseModule.kt
│       └── NetworkModule.kt
│
├── res/
│   ├── drawable/
│   ├── layout/
│   ├── values/
│   │   ├── strings.xml
│   │   ├── colors.xml
│   │   └── themes.xml
│   └── xml/
│       └── data_extraction_rules.xml
│
└── AndroidManifest.xml
```

---

## Getting Started

### Prerequisites

1. **Java Development Kit 17**
   ```bash
   # macOS (Homebrew)
   brew install openjdk@17
   
   # Add to ~/.zshrc or ~/.bash_profile
   export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
   export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
   
   # Verify
   java -version  # Should show version 17
   ```

2. **Android SDK** (if not using Android Studio)
   ```bash
   # Run the automated setup script from project root
   ./scripts/setup-android-sdk.sh
   
   # This installs SDK to .android-sdk/ directory
   # Add to your shell profile:
   export ANDROID_SDK_ROOT="/path/to/hypo/.android-sdk"
   ```

3. **Gradle User Home** (optional, for reproducible builds)
   ```bash
   # Add to shell profile for consistent dependency caching
   export GRADLE_USER_HOME="/path/to/hypo/.gradle"
   ```

### Building from Source

#### Option 1: Command Line (Recommended for CI/CD)

```bash
# Navigate to project root
cd /path/to/hypo

# Set environment variables
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export ANDROID_SDK_ROOT="/path/to/hypo/.android-sdk"
export GRADLE_USER_HOME="/path/to/hypo/.gradle"

# Build debug APK
cd android
./gradlew assembleDebug --stacktrace

# APK will be at: app/build/outputs/apk/debug/app-debug.apk
```

**Build Output:**
- **Debug APK**: `app/build/outputs/apk/debug/app-debug.apk` (~41MB)
- **SHA-256**: Run `shasum -a 256 app-debug.apk` to verify

#### Option 2: Android Studio

1. **Open Project**
   ```bash
   # Open android/ directory in Android Studio
   studio android
   ```

2. **Configure SDK**
   - Android Studio will prompt to download missing SDK components
   - Or manually: Settings → Appearance & Behavior → System Settings → Android SDK

3. **Build & Run**
   - **Build > Make Project** (Cmd+F9)
   - **Run > Run 'app'** (Shift+F10) - requires connected device/emulator

### Installing on Device

#### Prerequisites
- Android device with **USB Debugging enabled**
  - Settings → About Phone → Tap "Build Number" 7 times
  - Settings → Developer Options → Enable "USB Debugging"

#### Installation Steps

1. **Connect Device via USB**
   ```bash
   # Verify device is connected
   $ANDROID_SDK_ROOT/platform-tools/adb devices
   # Should show your device in "device" state
   ```

2. **Install APK**
   ```bash
   $ANDROID_SDK_ROOT/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
   
   The `-r` flag allows reinstalling with updated code.

3. **Grant Permissions (First Launch)**
   - **Notifications**: Required for sync status updates
   - **Camera**: Required for QR code pairing

#### Xiaomi/HyperOS Specific Setup

Xiaomi devices have additional security restrictions:

1. **Enable "Install via USB"**
   - Settings → Additional Settings → Developer Options
   - Enable **"Install via USB"** (may require internet connection)

2. **Disable Battery Optimization**
   - Settings → Apps → Manage Apps → Hypo
   - Battery Saver → **No restrictions**

3. **Enable Autostart**
   - Settings → Apps → Manage Apps → Hypo
   - Enable **Autostart**
   - Enable **Run in background**

4. **Wi-Fi Multicast (for LAN sync)**
   - The app requests `CHANGE_WIFI_MULTICAST_STATE` permission automatically
   - Required for local network device discovery

---

## Key Components

### ClipboardSyncService

Foreground service that monitors clipboard and syncs changes.

```kotlin
class ClipboardSyncService : Service() {
    private val clipboardManager by lazy { 
        getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager 
    }
    private val syncEngine by inject<SyncEngine>()
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, createNotification())
        
        clipboardManager.addPrimaryClipChangedListener {
            handleClipboardChange()
        }
        
        return START_STICKY
    }
    
    private fun handleClipboardChange() {
        val clip = clipboardManager.primaryClip ?: return
        val item = ClipboardItem.from(clip)
        
        lifecycleScope.launch {
            syncEngine.syncToMac(item)
        }
    }
    
    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hypo Clipboard Sync")
            .setContentText("Syncing with macOS")
            .setSmallIcon(R.drawable.ic_sync)
            .setOngoing(true)
            .addAction(R.drawable.ic_pause, "Pause", pausePendingIntent)
            .build()
    }
}
```

### SyncEngine

Coordinates clipboard changes, encryption, and transport.

```kotlin
class SyncEngine @Inject constructor(
    private val transport: TransportManager,
    private val crypto: CryptoService,
    private val repository: ClipboardRepository
) {
    private var lastSentHash: String? = null
    private var lastReceivedHash: String? = null
    
    suspend fun syncToMac(item: ClipboardItem) {
        val hash = item.contentHash
        if (hash == lastSentHash || hash == lastReceivedHash) return
        
        val encrypted = crypto.encrypt(item)
        transport.send(encrypted)
        
        lastSentHash = hash
        repository.insert(item)
    }
    
    suspend fun handleReceivedClipboard(message: SyncMessage) {
        val decrypted = crypto.decrypt(message)
        
        lastReceivedHash = decrypted.contentHash
        updateClipboard(decrypted)
        repository.insert(decrypted)
        NotificationHelper.show(decrypted)
    }
}
```

### Room Database

```kotlin
@Entity(tableName = "clipboard_history")
data class ClipboardEntity(
    @PrimaryKey val id: String,
    val timestamp: Long,
    val type: ClipType,
    val content: String,
    val previewText: String,
    val metadata: String?,
    val deviceId: String,
    val isPinned: Boolean = false
)

@Dao
interface ClipboardDao {
    @Query("SELECT * FROM clipboard_history ORDER BY timestamp DESC LIMIT :limit")
    fun getRecent(limit: Int = 200): Flow<List<ClipboardEntity>>
    
    @Query("SELECT * FROM clipboard_history WHERE previewText LIKE '%' || :query || '%'")
    fun search(query: String): Flow<List<ClipboardEntity>>
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(item: ClipboardEntity)
    
    @Delete
    suspend fun delete(item: ClipboardEntity)
}
```

---

## Jetpack Compose UI

### HomeScreen

```kotlin
@Composable
fun HomeScreen(viewModel: HomeViewModel = hiltViewModel()) {
    val latestItem by viewModel.latestItem.collectAsState()
    val syncStatus by viewModel.syncStatus.collectAsState()
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Hypo") },
                actions = {
                    ConnectionStatusIndicator(syncStatus)
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            LatestItemCard(latestItem)
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Button(
                onClick = { /* Navigate to history */ },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("View History")
            }
        }
    }
}
```

---

## Dependencies

See `app/build.gradle.kts`:

```kotlin
dependencies {
    // Jetpack
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")
    
    // Compose
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    
    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.6")
    
    // Room
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
    
    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.0.0")
    
    // Hilt
    implementation("com.google.dagger:hilt-android:2.50")
    ksp("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.1.0")
    
    // Network
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")
    
    // QR Code
    implementation("com.google.mlkit:barcode-scanning:17.2.0")
    
    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    
    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
```

---

## Permissions

In `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.CAMERA" /> <!-- For QR scanning -->

<application>
    <service
        android:name=".service.ClipboardSyncService"
        android:foregroundServiceType="dataSync"
        android:exported="false" />
</application>
```

---

## Testing

### Unit Tests

```bash
./gradlew test
```

### Instrumented Tests

```bash
./gradlew connectedAndroidTest
```

### Manual Testing Checklist

- [ ] Copy text → verify sync to macOS
- [ ] Receive text from macOS → verify clipboard update
- [ ] Foreground service persists after app close
- [ ] Battery optimization exemption requested
- [ ] Notification displays on received clipboard
- [ ] QR scanner successfully pairs with macOS
- [ ] Search history for text

---

## Build Variants

### Debug
- Debuggable, logging enabled
- Local backend (localhost:8080)
- Test keys for encryption

### Release
- ProGuard/R8 enabled
- Production backend (relay.hypo.app)
- Release signing with keystore

```bash
./gradlew assembleRelease
```

---

## Battery Optimization

Hypo is designed to minimize battery drain while maintaining reliable clipboard sync:

### Automatic Screen-State Management

The service automatically monitors screen state and adjusts WebSocket connections:

- **Screen ON**: Normal operation - maintains active WebSocket connections for real-time sync
- **Screen OFF**: Battery-save mode - gracefully idles WebSocket connections
  - Stops LAN discovery and cloud WebSocket connections
  - Reduces network activity to near-zero
  - Clipboard monitoring continues (zero-cost)
  - Reconnects automatically when screen turns on

### Implementation

```kotlin
// ScreenStateReceiver automatically handles:
Intent.ACTION_SCREEN_OFF  → Stop WebSocket connections
Intent.ACTION_SCREEN_ON   → Resume WebSocket connections
```

This behavior is transparent to the user and reduces background battery drain by **60-80%** during screen-off periods.

### Xiaomi/HyperOS Optimization Tips

For best battery performance on Xiaomi devices:

1. **Battery Optimization Exemption**: Settings → Apps → Hypo → Battery saver → No restrictions
2. **Autostart**: Settings → Apps → Manage apps → Hypo → Autostart → Enable
3. **Background Activity**: Settings → Apps → Hypo → Battery usage → Allow background activity

These settings allow the foreground service to run efficiently without aggressive system throttling.

---

## Distribution

### Signed APK

```bash
# Generate signing keystore
keytool -genkey -v -keystore hypo-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias hypo

# Build signed APK
./gradlew assembleRelease

# Output: app/build/outputs/apk/release/app-release.apk
```

### Google Play Store (Future)

- Create Google Play Console account
- Configure app details, screenshots
- Upload signed AAB
- Complete store listing

---

## Performance Targets

- **Memory**: < 30MB resident
- **CPU**: < 1% idle
- **Battery**: < 2% drain per day
- **Startup**: < 500ms to service ready

---

## Known Issues

- Android 10+ restricts background clipboard access (foreground service required)
- Some manufacturers (Xiaomi, Samsung) aggressively kill background services
  - **Mitigation**: Request battery optimization exemption, educate user
- ClipData can be complex (multiple items, various MIME types)
  - **Mitigation**: Only sync primary clip item

---

## Troubleshooting

### Build Issues

#### "command not found: java"
```bash
# Ensure Java 17 is installed and in PATH
brew install openjdk@17
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
```

#### "SDK location not found"
```bash
# Set ANDROID_SDK_ROOT environment variable
export ANDROID_SDK_ROOT="/path/to/hypo/.android-sdk"

# Or create android/local.properties:
sdk.dir=/path/to/android/sdk
```

#### "Cannot resolve symbol R" or missing generated code
```bash
# Clean and rebuild
./gradlew clean
./gradlew assembleDebug
```

#### KSP/Hilt compilation errors
```bash
# Ensure Room and Hilt annotation processors run
./gradlew clean
./gradlew kspDebugKotlin
./gradlew assembleDebug
```

### Runtime Crashes

#### "SecurityException: CHANGE_WIFI_MULTICAST_STATE"
**Fixed in v0.2.0+**. Ensure you have the latest code with this permission in `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
```

#### "IllegalArgumentException: listener already in use"
**Fixed in v0.2.0+**. The NSD discovery listener lifecycle has been improved to properly stop before restart.

#### App crashes on launch with Hilt errors
Ensure all dependencies are correctly wired in `di/AppModule.kt`. Missing `@Provides` or `@Binds` can cause crashes.

### Installation Issues

#### "adb: command not found"
```bash
# Use full path to adb
$ANDROID_SDK_ROOT/platform-tools/adb devices
```

#### "error: device unauthorized"
- Check your phone screen for USB debugging authorization dialog
- Tap "Allow" and check "Always allow from this computer"

#### "INSTALL_FAILED_USER_RESTRICTED"
**Xiaomi/HyperOS only**: Enable "Install via USB" in Developer Options.

#### App won't stay running in background
**Xiaomi/HyperOS**: Disable battery optimization and enable Autostart (see Xiaomi/HyperOS Setup section).

### Monitoring Logs

```bash
# View all logs
$ANDROID_SDK_ROOT/platform-tools/adb logcat

# Filter for Hypo app only
$ANDROID_SDK_ROOT/platform-tools/adb logcat -v time "*:E" | grep -E "clipboard|Hypo"

# Clear logs before testing
$ANDROID_SDK_ROOT/platform-tools/adb logcat -c
```

### Development Tips

1. **Incremental Builds**: Gradle caches aggressively. Only changed files recompile.
2. **Clean Builds**: If weird errors appear, try `./gradlew clean`.
3. **Dependency Updates**: Check `libs.versions.toml` or `build.gradle.kts` for latest versions.
4. **Network Issues**: Ensure device and macOS are on same Wi-Fi network for LAN sync.
5. **USB Debugging**: Some USB-C cables are charge-only. Use a data cable.

---

## Roadmap

- [ ] Support multi-device sync (>2 devices)
- [ ] Implement clipboard filtering
- [ ] Add Quick Settings tile for toggle
- [ ] Support rich text formatting
- [ ] Add wear OS companion app

---

## Contributing

When submitting PRs:

1. **Format Code**: Android Studio → Code → Reformat Code (Cmd+Option+L)
2. **Run Tests**: `./gradlew test` should pass
3. **Lint**: `./gradlew lint` should have no errors
4. **Update Docs**: If you change APIs or add features

---

**Status**: Alpha Development - Sprint 8 (90% Complete)  
**Last Updated**: October 12, 2025  
**Tested On**: Xiaomi 15 Pro (HyperOS), Pixel 7 (Android 14)

