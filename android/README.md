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

### 1. Clone and Open

```bash
cd android
./gradlew build
```

Open in Android Studio:
```bash
studio .
```

### 2. Configure

Create `local.properties` if not exists:
```properties
sdk.dir=/Users/yourname/Library/Android/sdk
```

### 3. Build and Run

```bash
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

Or in Android Studio: **Run > Run 'app'** (Shift+F10)

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

## Roadmap

- [ ] Support multi-device sync (>2 devices)
- [ ] Implement clipboard filtering
- [ ] Add Quick Settings tile for toggle
- [ ] Support rich text formatting
- [ ] Add wear OS companion app

---

**Status**: In Development  
**Last Updated**: October 1, 2025

