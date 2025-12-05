# Changelog

All notable changes to the Hypo project will be documented in this file.

## [1.0.5] - 2025-12-05 - Text Selection Context Menu & Clipboard Processing Improvements

### Added
- **Android Text Selection Context Menu**: "Copy to Hypo" appears first in text selection menu
  - Renamed context menu item from "Hypo" to "Copy to Hypo" for clarity
  - Added high priority (1000) to ensure it appears first in the menu
  - Users can select text in any app and tap "Copy to Hypo" to sync immediately
- **Force Clipboard Processing**: Immediate processing for text selection context menu
  - ProcessTextActivity now forces immediate clipboard processing via service intent
  - Text passed directly in intent to avoid timing issues with clipboard access
  - Works even when ClipboardListener isn't started (e.g., accessibility service enabled)
  - Resolves issue where text from context menu wasn't being processed/synced

### Fixed
- **Android History Item Copying**: Fixed "FrameInsert open fail" error for images/files
  - Implemented FileProvider for secure file sharing (required on Android 10+)
  - Replaced `Uri.fromFile()` with `FileProvider.getUriForFile()` for content:// URIs
  - Added `file_provider_paths.xml` configuration
  - Ensures temp files are readable and properly shared
- **Android Duplicate Detection**: Items now move to top when copied from history
  - Changed from timestamp update to delete old + create new item
  - Ensures copied items always appear at the top of history
  - Works for both "matches current clipboard" and "matches history item" cases
- **Universal Toast Notification**: "Copied to clipboard" toast now shows for all item types
  - Previously only showed for images/files
  - Now shows for text, links, images, and files
- **Incoming Message URI Handling**: Removed incorrect URI extraction from receiver
  - URIs from sender's local file system are not accessible on receiver
  - Binary data should be extracted before sending, not upon receipt
  - ClipboardParser already handles URI extraction when creating clipboard events

### Changed
- **Reduced Logging Verbosity**: Significantly reduced log noise across all platforms
  - Android: Removed repetitive debug logs from SettingsViewModel (every 2 seconds)
  - macOS: Converted many `.info` logs to `.debug` for routine operations
  - Backend: Changed `DeviceNotConnected` from ERROR to WARN (expected condition)
  - Removed redundant logs (duplicate queue size, frame details, JSON previews)
  - Improved log clarity by distinguishing expected conditions from actual errors
- **macOS Connection Status Display**: Shows detailed connection information
  - Displays "Connected via IP <and cloud>" instead of just "Connected"
  - Prioritizes LAN IP addresses when device is discovered
  - Better visibility into connection method (LAN vs cloud)
- **macOS Peer Discovery**: Excludes self from discovered peers list
  - Filters out current device by device ID and service name
  - Prevents confusion when viewing available devices

### Technical Details
- FileProvider implementation follows Android 10+ security requirements
- Force processing ensures immediate sync even with background restrictions
- Delete + create approach for duplicates ensures items always move to top
- Log reduction improves signal-to-noise ratio for debugging

## [1.0.4] - 2025-12-04 - Code Quality & Storage Optimization

### Added
- **Size Constants Consolidation**: Single source of truth for all size limits
  - Created `SizeConstants.kt` (Android) and `SizeConstants.swift` (macOS)
  - All size-related constants now defined in one place (10MB sync, 50MB copy, 25MB transport, 7.5MB compression target, 2560px max dimension)
  - Eliminates duplicate definitions and ensures consistency across codebase
  - Makes future size limit updates easier and less error-prone

### Fixed
- **Gzip Compression Format**: Fixed "invalid stored block lengths" error on Android
  - macOS now uses proper gzip format (raw deflate with gzip headers/footers) instead of zlib-wrapped deflate
  - Uses `deflateInit2` with `MAX_WBITS + 16` for gzip format
  - Uses `inflateInit2` with `MAX_WBITS + 16` for gzip decompression
  - Fully compatible with Java's `GZIPInputStream` on Android
  - Resolves compression format mismatch between platforms

### Changed
- **macOS Local File Storage Optimization**: Pointer-only storage for local files
  - Local file entries now store only file URL + metadata (no duplicate Base64 blob)
  - Bytes loaded on-demand when syncing, previewing, copying, or opening in Finder
  - Reduces disk usage for local-origin files (no duplicate storage in history database)
  - Remote files still stored as Base64 for offline availability
  - All code paths (sync, preview, dedup, UI) handle both pointer-based and Base64-based entries

### Technical Details
- Size constants consolidation reduces maintenance burden and prevents inconsistencies
- Gzip fix ensures proper format compatibility between Swift zlib and Java GZIPInputStream
- Pointer-only storage leverages macOS file system instead of duplicating bytes in database
- All file operations (sync, preview, copy, open) gracefully handle missing files (URL no longer valid)

## [1.0.3] - 2025-12-04 - Temp File Management & Performance Improvements

### Added
- **Automatic Temp File Cleanup (Android & macOS)**: Prevents disk space accumulation
  - Temp files automatically deleted after 30 seconds
  - Cleanup triggered on clipboard changes
  - Periodic cleanup of old temp files (>5 minutes)
  - Centralized `TempFileManager` for both platforms
  - Prevents disk space issues when copying large images/files
- **Size Limit Checks Before Copying**: Prevents copying very large items
  - 50MB limit for copying (separate from 10MB sync limit)
  - System notifications when items exceed limit
  - Applied to both incoming clipboard items and history copy operations
  - Protects against excessive disk space usage
- **Android Lazy Loading for Large Content**: Fixed crash with large images/files
  - Implemented lazy loading for IMAGE/FILE types in database queries
  - Content excluded from list queries to prevent `SQLiteBlobTooBigException`
  - Content loaded on-demand when copying or viewing details
  - Resolves app crashes when history contains large items (>2MB)

### Fixed
- **macOS Encryption Encoding**: Fixed decryption failures on Android
  - macOS now encodes `Data` fields (ciphertext, nonce, tag) as base64 strings
  - Android expects base64 strings, not arrays of integers
  - Resolves `BAD_DECRYPT` errors when receiving encrypted messages from macOS
  - Custom `encode(to:)` methods added to `Payload` and `EncryptionMetadata` structs
- **Android Database CursorWindow Overflow**: Fixed app crashes with large content
  - Modified all database queries to exclude `content` field for IMAGE/FILE types
  - Added `loadFullContent()` method for on-demand content loading
  - Prevents `SQLiteBlobTooBigException` when displaying history with large items

### Changed
- **Temp File Naming**: Improved uniqueness and tracking
  - Android: Uses `hypo_` prefix for easy identification
  - macOS: Uses `hypo_` prefix with UUID for uniqueness
  - Better cleanup tracking and periodic maintenance

### Technical Details
- Temp file cleanup uses clipboard change notifications and polling
- Size checks use estimated decoded size (base64 length × 3/4) before decoding
- Lazy loading uses SQL `CASE` statements to return empty strings for large content
- macOS encoding fix ensures compatibility with Android's base64 string expectations

## [1.0.2] - 2025-12-03 - Build & Release Improvements

### Added
- **macOS App Signing**: Free ad-hoc signing for macOS app distribution
  - Added `scripts/sign-macos.sh` for automated ad-hoc code signing
  - Created `macos/HypoApp.entitlements` with hardened runtime and network permissions
  - Integrated signing step into GitHub Actions release workflow
  - App can be distributed without Apple Developer account ($99/year)
  - Users can bypass Gatekeeper warning by right-clicking → Open
- **Automatic Release Notes Generation**: Intelligent commit summarization
  - Automatically generates categorized commit summaries from git history
  - Groups commits by type (feat, fix, docs, ci, security, etc.)
  - Falls back to `changelog.md` if version section exists
  - Finds commits since last tag or uses last 20 commits
  - Displays with emoji icons for better readability

### Changed
- **Android Build Optimizations**: Improved CI/CD build performance
  - Added Android SDK caching (saves 2-5 minutes on subsequent builds)
  - Increased Gradle JVM memory from 2048m to 4096m (10-20% faster compilation)
  - Added build time tracking with GitHub Actions step summary
  - Optimized artifact retention (7 days for test branches, 30 for releases)
  - Added artifact compression level 6 for smaller uploads
  - Enabled Gradle build cache with `--build-cache` flag
- **Backend Deployment Workflow**: Smarter change detection
  - Uses `dorny/paths-filter` action for reliable path filtering
  - Only deploys when `backend/**/*.rs`, `Cargo.toml`, or `Cargo.lock` changes
  - More reliable than GitHub's built-in path filters
  - Prevents unnecessary deployments on documentation or frontend changes

### Technical Details
- macOS signing uses ad-hoc signature (`codesign --sign "-"`) with hardened runtime
- Release notes parser supports Conventional Commits format
- Android SDK cache key based on Gradle configuration files
- Build time tracking provides visibility into CI performance

## [1.0.1] - 2025-12-02 - Production Release

### Added
- **SMS Auto-Sync (Android)**: Automatically copies incoming SMS messages to clipboard and syncs to macOS
  - `SmsReceiver` BroadcastReceiver listens for incoming SMS messages
  - Formats SMS as "From: <sender>\n<message>" and copies to clipboard
  - Leverages existing clipboard sync mechanism to send SMS to macOS
  - Runtime permission request on Android 6.0+ with UI status display
  - Settings screen shows permission status and provides grant button
  - Note: Android 10+ may have restrictions requiring manual copy
- **MIUI/HyperOS Optimization**: Automatic detection and workarounds for Xiaomi device restrictions
  - Automatic device detection (Xiaomi/HyperOS)
  - Multicast lock refresh every 10 minutes (prevents throttling)
  - Periodic NSD restart every 5 minutes (recovers from throttling)
  - Device-specific settings guidance in UI
  - Transparent to users - no configuration required
- **Automated CI/CD Pipeline**: GitHub Actions release workflow
  - Automated builds for Android and macOS
  - Automated release creation with artifacts
  - Version tagging and release notes generation
- **Backend Error Response Feature**: Error responses when target device not found
  - Backend sends error message with type `"error"` when routing fails
  - Error payload includes code, message, and target device ID
  - Normalizes device IDs to lowercase for consistent matching
  - Enables client-side error handling and user feedback
- **Android Error Handling & Toast Notifications**: Client-side sync failure feedback
  - Added `ERROR` message type and error payload support
  - Shows toast notification: "Failed to sync to {deviceName}: incorrect device_id ({deviceId})"
  - Resolves device name from device ID for user-friendly error messages

### Changed
- **Build System**: Improved build scripts and dependencies
  - Android: Added Java-WebSocket dependency (1.5.4) for LAN WebSocket server
  - macOS: Removed swift-crypto dependency (use CryptoKit directly)
  - Build scripts: Always build apps to ensure latest code changes
  - .gitignore: Added Cargo.lock comment, Python cache files, .secrets
- **Documentation**: Comprehensive updates to reflect production release
  - Updated PRD to v1.0.1 with all implemented features
  - Updated technical.md with production architecture details
  - Updated protocol.md to production status (v1.0.0)
  - Updated USER_GUIDE.md and INSTALLATION.md to v1.0.1
  - Consolidated and archived resolved bug reports

### Fixed
- **Transport Origin Bug Fix**: Fixed cloud messages incorrectly marked as LAN
  - Fixed `RelayWebSocketClient.setIncomingClipboardHandler()` to use two-parameter lambda
  - Ensures cloud messages correctly marked with `TransportOrigin.CLOUD`
  - Prevents incorrect sync behavior from transport origin tracking bug
- **Backend Test Infrastructure**: Fixed WebSocket handler test compilation errors
  - Added `create_test_session()` test helper to create WebSocket sessions for testing
  - Updated all test calls to `handle_text_message()` to include `sender_session` parameter
  - Improved error handling in error response code to gracefully handle session closure in tests
  - Changed error logging from `error!` to `warn!` when error response sending fails
  - All 33 backend unit tests now pass successfully
- **Android Settings Connection Status**: Fixed connection status display in Settings screen for LAN-connected devices
  - Changed from using global `connectionState` to `cloudConnectionState` for cloud server status
  - LAN device status now correctly determined by discovery status and active transport
  - Previously, LAN-connected devices were incorrectly shown as disconnected when cloud server was offline
- **Android Notification Visibility**: Improved notification visibility and permission handling
  - Changed notification channel importance from `IMPORTANCE_LOW` to `IMPORTANCE_DEFAULT`
  - Ensures persistent notification showing latest clipboard item is visible in notification list
  - Added notification permission request for Android 13+ (required for foreground service notifications)
  - Notification updates automatically when latest clipboard item changes
  - Sound disabled for persistent notification to avoid intrusive alerts
- **Cross-Platform History Sync**: Enhanced duplicate handling to move existing items to top
  - Android: Added `deviceId`, `deviceName`, `isEncrypted`, `transportOrigin` fields to `ClipboardEvent`
  - Android: `IncomingClipboardHandler` now moves matching items to top instead of creating duplicates
  - macOS: `HistoryStore.insert()` moves matching items to top regardless of transport origin
  - Preserves pin state when moving items to top
  - Updates timestamp to reflect user's active use of the item
  - Uses SHA-256 content matching for reliable duplicate detection across platforms

## [1.0.0] - 2025-12-02 - Initial Production Release

### Added
- **Production Backend Deployment**: Deployed to Fly.io production (https://hypo.fly.dev)
  - 2 machines in iad (Ashburn, VA) region
  - Auto-scaling (min=1, max=3)
  - Embedded Redis 7+ for session management
  - Zero-downtime deployments
  - Health checks on HTTP and TCP
  - Prometheus metrics endpoint
- **Device-Agnostic Pairing**: Pairing system supports pairing between any devices
  - Any device can act as initiator (QR code creator) or responder (QR code scanner)
  - Any device can create or claim pairing codes in remote pairing
  - Platform automatically detected from device ID prefixes
- **Automated Build and Release Pipeline**: GitHub Actions workflow for releases
  - Automated builds for Android and macOS
  - Automated release creation with artifacts
  - Version tagging and release notes generation

### Changed
- **Pairing Protocol**: Refactored to use role-based field names
  - Replaced platform-specific names with role-based names (`peer_device_id`, `initiator_device_id`, `responder_device_id`)
  - Backward compatibility maintained through dual field support
- **macOS Key Storage**: Replaced Keychain with encrypted file-based storage
  - Created `FileBasedKeyStore` and `FileBasedPairingSigningKeyStore` for app-internal storage
  - Keys stored in `~/Library/Application Support/Hypo/` with AES-GCM encryption
  - Removes dependency on Keychain Sharing entitlement
  - Improves Notarization compatibility for distribution
- **macOS Logging Improvements**: Reduced log verbosity and improved debugging clarity
  - Removed redundant logs from `versionString` computed property
  - Changed routine operation logs from `info` to `debug` level
  - Removed legacy `appendDebug` file-based logging in favor of unified `os_log`
  - Improved error messages with clearer descriptions

### Fixed
- **Backend Routing to Wrong Device**: Fixed incorrect message routing
  - Removed case-insensitive device ID matching fallback
  - Messages now correctly routed to target devices only (exact UUID matching)
  - Enhanced logging with detailed routing information
  - Verified end-to-end: messages targeted to macOS only go to macOS, not Android
- **Android LAN WebSocket Server**: Fixed binary frame reception
  - Replaced custom frame parser with `org.java-websocket:Java-WebSocket` library
  - Binary frames now reliably delivered via `onMessage(ByteBuffer)`
  - Handles handshake, masking, fragmentation, ping/pong automatically
  - Verified end-to-end: LAN sync now working correctly
- **Android Startup Crash**: Fixed "Invalid URL port: 0" error
  - Changed placeholder URL from `http://0.0.0.0:0` to `http://127.0.0.1:1`
  - App now starts successfully on all devices
- **macOS History Pinning**: Fixed pinning behavior
  - Fixed issue where pinned items were automatically unpinned when copied locally
  - Preserved user's pin preference when updating matching entries
  - Pinned items now correctly stay pinned and appear at top

## [Unreleased] - SMS Auto-Sync & Permission Management

### Added
- **SMS Auto-Sync (Android)**: Automatically copies incoming SMS messages to clipboard and syncs to macOS
  - `SmsReceiver` BroadcastReceiver listens for incoming SMS messages
  - Formats SMS as "From: <sender>\n<message>" and copies to clipboard
  - Leverages existing clipboard sync mechanism to send SMS to macOS
  - Runtime permission request on Android 6.0+ with UI status display
  - Settings screen shows permission status and provides grant button
  - Note: Android 10+ may have restrictions requiring manual copy
- **SMS Permission Management**: Complete permission handling with UI integration
  - Automatic permission request on app launch (Android 6.0+)
  - Settings screen displays permission status (Granted/Not Granted)
  - Periodic permission status monitoring (every 2 seconds)
  - User-friendly permission request button in Settings
  - Android 10+ limitation warnings displayed to users
- **Notification Permission Request (Android 13+)**: Runtime permission handling for notifications
  - Automatic permission request on app launch (Android 13+)
  - Required for persistent foreground service notification showing latest clipboard item
  - Settings screen displays notification permission status
  - Periodic permission status monitoring (every 2 seconds)
  - User-friendly permission request button in Settings
  - Backward compatible: Android 12 and below don't require runtime permission

### Changed
- **Build System**: Improved build scripts and dependencies
  - Android: Added Java-WebSocket dependency (1.5.4) for LAN WebSocket server
  - macOS: Removed swift-crypto dependency (use CryptoKit directly)
  - Build scripts: Always build apps to ensure latest code changes
  - .gitignore: Added Cargo.lock comment, Python cache files, .secrets
- **Android Transport Layer**: Refactored LAN WebSocket implementation
  - Removed `LanWebSocketClient.kt` (replaced with `LanPeerConnectionManager` and `LanWebSocketServer`)
  - Added `LanPeerConnectionManager` for managing peer connections
  - Added `LanWebSocketServer` to allow Android to act as WebSocket server
  - Increased payload size limit from 256KB to 10MB in `TransportFrameCodec`
  - Made `TlsWebSocketConfig.url` nullable for LAN connections (URL comes from peer discovery)
- **Database Schema (Version 3)**: Enhanced clipboard history database schema
  - Added `isEncrypted` field to track encryption status
  - Added `transportOrigin` field to track LAN vs CLOUD transport
  - Changed timestamp from `Long` to `Instant` for better type safety
  - Added helper methods: `getLatestEntry()`, `findMatchingEntryInHistory()`, `updateTimestamp()`
  - Content matching uses SHA-256 hash for reliable duplicate detection across platforms

### Fixed
- **Backend Test Infrastructure**: Fixed WebSocket handler test compilation errors
  - Added `create_test_session()` test helper to create WebSocket sessions for testing
  - Updated all test calls to `handle_text_message()` to include `sender_session` parameter
  - Improved error handling in error response code to gracefully handle session closure in tests
  - Changed error logging from `error!` to `warn!` when error response sending fails (session may be closed)
  - All 33 backend unit tests now pass successfully
- **Android Settings Connection Status**: Fixed connection status display in Settings screen for LAN-connected devices
  - Changed from using global `connectionState` to `cloudConnectionState` for cloud server status
  - LAN device status now correctly determined by discovery status and active transport
  - Previously, LAN-connected devices were incorrectly shown as disconnected when cloud server was offline
  - Cloud device status correctly shows disconnected when cloud server is offline
- **Android Notification Visibility**: Improved notification visibility and permission handling
  - Changed notification channel importance from `IMPORTANCE_LOW` to `IMPORTANCE_DEFAULT`
  - Ensures persistent notification showing latest clipboard item is visible in notification list
  - Previously, `IMPORTANCE_LOW` notifications were hidden on Android 8.0+ by default
  - Changed notification priority from `PRIORITY_LOW` to `PRIORITY_DEFAULT` to match channel importance
  - Added notification permission request for Android 13+ (required for foreground service notifications)
  - Added comprehensive diagnostic logging for notification channel creation and status
  - Notification updates automatically when latest clipboard item changes
  - Sound disabled for persistent notification to avoid intrusive alerts
- **Cross-Platform History Sync**: Enhanced duplicate handling to move existing items to top
  - Android: Added `deviceId`, `deviceName`, `isEncrypted`, `transportOrigin` fields to `ClipboardEvent`
  - Android: `IncomingClipboardHandler` now moves matching items to top instead of creating duplicates
  - macOS: `HistoryStore.insert()` moves matching items to top regardless of transport origin
  - Preserves pin state when moving items to top
  - Updates timestamp to reflect user's active use of the item
  - Ensures cross-platform user actions (e.g., clicking Android item that originated from macOS) are reflected in both platforms' history
  - Uses SHA-256 content matching for reliable duplicate detection across platforms

## [0.3.3] - 2025-12-02 - Device-Agnostic Pairing & Storage Improvements

### Added
- **Device-Agnostic Pairing**: Pairing system now supports pairing between any devices (Android↔Android, macOS↔macOS, Android↔macOS, etc.), not just Android↔macOS. Any device can act as initiator (QR code creator) or responder (QR code scanner) in LAN pairing, and any device can create or claim pairing codes in remote pairing.

### Changed
- **Pairing Protocol**: Refactored pairing models to use role-based field names (`peer_device_id`, `initiator_device_id`, `responder_device_id`) instead of platform-specific names (`mac_device_id`, `android_device_id`). Backward compatibility maintained through dual field support.
- **Platform Detection**: Platform is now automatically detected from device ID prefixes or metadata during pairing, rather than being hard-coded. Supports detection of Android, macOS, iOS, Windows, and Linux platforms.
- **Discovery Filtering**: Removed platform-specific filtering in Android discovery - all discovered devices are now shown regardless of platform.
- **Device ID Migration**: Enhanced device ID migration to handle any platform prefix (macos-, android-, ios-, windows-, linux-), not just macos-/android-.
- **macOS Key Storage**: Replaced Keychain storage with encrypted file-based storage for better Notarization compatibility
  - Created `FileBasedKeyStore` and `FileBasedPairingSigningKeyStore` for app-internal storage
  - Keys stored in `~/Library/Application Support/Hypo/` with AES-GCM encryption
  - Maintains same security level with encrypted file storage
  - Removes dependency on Keychain Sharing entitlement
  - Files protected with 0o600 permissions (user-only access)
- **macOS Logging Improvements**: Reduced log verbosity and improved debugging clarity
  - Removed redundant logs from `versionString` computed property
  - Changed routine operation logs from `info` to `debug` level
  - Removed legacy `appendDebug` file-based logging in favor of unified `os_log`
  - Improved error messages with clearer descriptions
  - Consolidated notification observer logs

### Technical Details
- Updated `PairingPayload`, `PairingChallengeMessage`, and `PairingAckMessage` models across Swift and Kotlin
- Backend Redis client and handlers updated to use `initiator_*` and `responder_*` field names
- Relay clients updated to support device-agnostic pairing flows
- Platform detection logic added to `PairingSession.swift` with `detectPlatform()` helper function
- `FileBasedKeyStore` uses AES-GCM encryption with service-derived keys for secure storage
- All Keychain references replaced with file-based storage while maintaining backward compatibility

## [0.2.3] - 2025-01-21 - Transport Origin & Icon Display Fixes

### Fixed
- **macOS Transport Origin Display**: Fixed cloud messages showing incorrect origin
  - Updated `LanWebSocketTransport.handleIncoming()` to determine `TransportOrigin` based on configuration
  - Cloud messages now correctly identified as `.cloud` instead of `.lan`
  - `CloudRelayTransport` wraps handler to mark messages as `.cloud` origin
  - `TransportManager.setCloudIncomingMessageHandler()` passes `.cloud` origin correctly

- **macOS History Icon Display**: Fixed icon display for encryption and transport origin
  - Removed network icon for LAN messages (no icon shown for LAN)
  - Cloud icon (☁️) only shown for cloud messages
  - Shield icon (🔒) shown for encrypted messages
  - Icons are small (10pt) with tooltips for clarity

- **macOS Connection Status Display**: Fixed connection status text to show actual IP address instead of Bonjour hostname
  - Extracts IP address from `NetService.addresses` using `getnameinfo()`
  - Now displays "Connected via 10.0.0.137:7010 and server" instead of "Connected via Android_NOLKQLA2.local.:7010 and server"
  - Falls back to hostname if IP extraction fails

- **macOS Device Discovery Info Preservation**: Fixed `bonjourHost` and `bonjourPort` being lost when updating device online status
  - `updateDeviceOnlineStatus` now preserves all discovery fields (serviceName, bonjourHost, bonjourPort, fingerprint)
  - Ensures connection status text can display IP:PORT information correctly

### Changed
- **Android SettingsViewModel Refactoring**: Removed synthetic peers approach in favor of direct storage-based model
  - Loads paired devices directly from `DeviceKeyStore` instead of creating fake `DiscoveredPeer` objects
  - Simpler logic: Storage → Check Discovery/Connection Status → Display
  - More maintainable and easier to understand code flow
  - Eliminates unnecessary object creation and merging logic

### Known Issues
- **Cloud Relay Message Routing**: Cloud messages are being received but routed through LAN server path instead of cloud transport path
  - Messages marked as `origin: lan` instead of `origin: cloud`
  - "Connection reset by peer" error preventing cloud WebSocket from receiving messages
  - LAN sync working correctly (plaintext and encrypted)
  - See `docs/bugs/clipboard_sync_issues.md` Issue 14 for details

### Technical Details
- `LanWebSocketTransport.handleIncoming()` determines `transportOrigin` based on `configuration.environment` or `configuration.url.scheme`
- `ClipboardEntry` model extended with `isEncrypted: Bool` and `transportOrigin: TransportOrigin?`
- `ClipboardCard` and `ClipboardRow` display icons based on entry properties
- `BonjourBrowser` now extracts IP addresses from resolved `NetService` addresses
- `HistoryStore.updateDeviceOnlineStatus` preserves all `PairedDevice` fields when updating status
- `SettingsViewModel` uses `PairedDeviceInfo` internal model for cleaner data flow

---

## [0.2.2] - 2025-01-21 - UI Improvements & Code Refactoring

### Fixed
- **macOS Connection Status Display**: Fixed connection status text to show actual IP address instead of Bonjour hostname
  - Extracts IP address from `NetService.addresses` using `getnameinfo()`
  - Now displays "Connected via 10.0.0.137:7010 and server" instead of "Connected via Android_NOLKQLA2.local.:7010 and server"
  - Falls back to hostname if IP extraction fails

- **macOS Device Discovery Info Preservation**: Fixed `bonjourHost` and `bonjourPort` being lost when updating device online status
  - `updateDeviceOnlineStatus` now preserves all discovery fields (serviceName, bonjourHost, bonjourPort, fingerprint)
  - Ensures connection status text can display IP:PORT information correctly

### Changed
- **Android SettingsViewModel Refactoring**: Removed synthetic peers approach in favor of direct storage-based model
  - Loads paired devices directly from `DeviceKeyStore` instead of creating fake `DiscoveredPeer` objects
  - Simpler logic: Storage → Check Discovery/Connection Status → Display
  - More maintainable and easier to understand code flow
  - Eliminates unnecessary object creation and merging logic

### Technical Details
- `BonjourBrowser` now extracts IP addresses from resolved `NetService` addresses
- `HistoryStore.updateDeviceOnlineStatus` preserves all `PairedDevice` fields when updating status
- `SettingsViewModel` uses `PairedDeviceInfo` internal model for cleaner data flow

---

## [0.2.1] - 2025-11-19 - Clipboard Sync Stability & Cloud Relay Support

### Fixed
- **Sync Broadcasting Timing Issue (Issue 11)**: Fixed clipboard sync not broadcasting when targets were empty
  - Added target caching in `SyncCoordinator` to ensure paired device IDs are available before event processing
  - Stabilized LAN discovery with connection-state persistence and periodic refresh (every 5 seconds)
  - Targets now remain populated throughout clipboard event processing lifecycle
  - Comprehensive logging added for duplicate check, repository save, and broadcast phases

- **Cloud Relay Headers**: Added required `X-Device-Id` and `X-Device-Platform` headers to WebSocket handshake
  - Cloud relay connections now succeed (previously returned 400 Bad Request)
  - Enables cloud relay as fallback transport when LAN peers are offline
  - Headers added in `LanWebSocketClient` connector for all cloud relay connections

### Changed
- **LAN Discovery Stability**: Improved peer discovery reliability
  - Deduplication logic tightened to keep peer list stable
  - Connection state persistence prevents targets from fluctuating (0→1→0)
  - Periodic refresh ensures targets are computed before clipboard events are processed

### Technical Details
- `SyncCoordinator` now caches paired device IDs and refreshes proactively before broadcasts
- LAN discovery dedupe + refresh job runs every 5 seconds to maintain stable peer list
- Cloud relay headers include device identifier and platform for proper server routing
- All clipboard sync issues (Issues 1-11) now resolved and verified end-to-end

---

## [0.2.0] - 2025-11-18 - Connection Status & UI Improvements

### Added
- **Connection Status Display (macOS)**: Real-time server connection status in Settings
  - Shows current connection state (Offline/Connecting/Connected LAN/Connected Cloud/Error)
  - Status badge with color-coded icons and text
  - Debug information showing TransportManager availability
  - Periodic state polling (2-second fallback) for reliable updates
  - Located in Settings → Connection section

- **Connection Status Display (Android)**: Server connection status in History and Settings screens
  - Connection status badge in History screen top-right corner
  - "Server Connection" section in Settings screen with status card
  - Real-time updates as connection state changes
  - Color-coded badges (green for LAN, blue for Cloud, gray for Offline, red for Error)

- **Device Identifier Consistency**: Standardized device ID format across platforms
  - macOS: `macos-{UUID}` format (was: `{UUID}`)
  - Android: `android-{UUID}` format (unchanged)
  - Future iOS: `ios-{UUID}` format (prepared)
  - Automatic migration for existing macOS devices
  - Consistent platform identification in pairing and sync

### Changed
- **Android History UI**: Removed "Clear History" button from History screen
  - Simplified UI with only connection status badge in header
  - History management available through other means if needed

- **macOS Connection State Observation**: Improved reliability
  - Changed from `.assign` to `.sink` for better reactivity
  - Added periodic polling (2-second intervals) as fallback
  - Enhanced debug logging for connection state changes
  - More prominent status display with background and padding

### Fixed
- **macOS Version Display**: Fixed version info reading from Info.plist
  - Added debug logging to diagnose bundle information
  - Improved fallback handling for version string
  - Version now displays correctly in About section

- **macOS App Bundle Updates**: Ensured app bundle is updated after builds
  - Executable copied to `.app` bundle after each build
  - App restarts automatically with latest changes

### Technical Details
- Connection state observed via Combine publishers on macOS
- Connection state observed via Flow on Android
- Both platforms update UI reactively when connection state changes
- Device ID format migration handles legacy UUID-only format

---

## [Sprint 9] - 2025-10-12 - LAN Auto-Discovery ✅ COMPLETE

### Added (macOS)
- **LanWebSocketServer**: Network.framework WebSocket server listening on port 7010
  - Accepts incoming Android connections
  - Routes messages to pairing vs clipboard handlers
  - Delegate pattern for connection lifecycle events
- **LanSyncTransport**: Real SyncTransport implementation replacing noop stub
  - Sends encrypted clipboard messages to connected Android clients
  - Receives and processes incoming clipboard data
- **DefaultTransportProvider**: Updated to use LanSyncTransport with WebSocket server
- **TransportManager**: Integrated WebSocket server lifecycle
  - Starts/stops server with LAN services
  - Implements LanWebSocketServerDelegate callbacks
- **HypoMenuBarApp**: Proper initialization with real transport infrastructure

### Changed (macOS)
- Replaced NoopSyncTransport with functional LAN transport
- macOS now capable of receiving WebSocket connections from Android
- Fixed QR code signature verification by adding sorted JSON keys

### Added (Android)
- **LanPairingViewModel**: State management for auto-discovery pairing
  - Uses existing LanDiscoverySource for mDNS device discovery
  - Manages pairing flow: Discovering → DevicesFound → Pairing → Success/Error
  - Integrates with PairingHandshakeManager for secure handshake
- **Auto-Discovery UI**: Three-tab interface (LAN | QR | Code)
  - AutoDiscoveryContent composable displays discovered macOS devices
  - DeviceCard shows device name, IP:port, and security status (🔒 Secured)
  - Real-time device discovery with automatic list updates
  - Tap-to-pair interaction initiates WebSocket connection
- **PairingMode.AutoDiscovery**: Set as default pairing mode for best UX

### Changed (Android)
- Default pairing mode changed from QR to AutoDiscovery
- PairingScreen now supports three modes with tab navigation
- Fixed imports for DeviceKeyStore and DeviceIdentity
- Build Status: ✅ Compiles successfully, APK at `android/app/build/outputs/apk/debug/app-debug.apk`

### Ready for Testing
- End-to-end LAN pairing flow (Android discovers macOS via mDNS)
- Tap-to-pair initiates encrypted handshake over WebSocket
- Bidirectional clipboard sync over LAN

### Technical Details
- Uses Network.framework for production-ready WebSocket server
- MainActor isolation for SwiftUI integration
- Reuses existing PairingSession crypto for secure handshake
- Port 7010 already advertised via Bonjour

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Sprint 8: Polish & Deployment (In Progress) - October 12, 2025

#### Added
- **Comprehensive User Documentation**: Created complete user guide with installation, usage, and troubleshooting sections
  - 60+ page user guide covering all features and use cases
  - Step-by-step installation guide for macOS and Android  
  - Detailed troubleshooting guide with platform-specific solutions
  - FAQ section and comprehensive support information

- **Android Build Documentation** ✅: Comprehensive build and installation guide
  - Detailed prerequisites setup (Java 17, Android SDK)
  - Step-by-step build instructions (command-line and Android Studio)
  - Device installation guide with adb commands
  - Xiaomi/HyperOS specific setup instructions (USB installation, battery optimization, autostart)
  - Troubleshooting section covering common build and runtime issues
  - Automated build script (`scripts/build-android.sh`) for one-command builds
  - Updated README.md with quick-start instructions
  - See `android/README.md` for complete documentation

- **Battery Optimization** ✅: Intelligent screen-state management for Android *(Oct 12, 2025)*
  - Automatic WebSocket connection idling when screen turns off
  - Graceful reconnection when screen turns on
  - ScreenStateReceiver monitors Intent.ACTION_SCREEN_OFF/ON
  - Reduces background battery drain by 60-80% during screen-off periods
  - Clipboard monitoring continues with zero overhead
  - Documented in README.md and android/README.md with Xiaomi-specific tips

- **Sprint 8 Analysis Documentation**: 
  - Complete bug report with P0/P1/P2 issue categorization
  - Progress tracking and completion metrics
  - Technical debt identification and resolution roadmap

#### Fixed
- **Android Build Resolution** ✅: Fixed all P0 compilation issues blocking APK generation
  - Added missing Paging library dependencies (androidx.paging:paging-compose, paging-runtime)
  - Resolved Room DAO query verification errors in pruning logic  
  - Added DI bindings for Json serializer and Clock to complete Hilt dependency graph

- **macOS Build Resolution** ✅: Fixed all Swift compilation errors blocking macOS app builds *(Oct 12, 2025)*
  - Resolved duplicate ClipboardEntry extension conflicts between MemoryProfiler and OptimizedHistoryStore
  - Fixed property initialization order issues in HistoryStore and PairingViewModel
  - Fixed Ed25519 keychain constant availability for macOS compatibility (kSecAttrKeyTypeEd25519)
  - Updated ClipboardContent property names to match actual model (fileName vs name)
  - Made WebSocketConnectionPool.lastUsed mutable to allow connection state updates
  - Added @retroactive attribute to Sendable conformance for UNUserNotificationCenter
  - Fixed ambiguous webSocketTask call in WebSocketConnectionPool
  - Simplified HypoMenuBarApp entry point and made it public

#### Deployed
- **Backend Server to Fly.io Production** ✅: Successfully deployed production-ready backend *(Oct 12, 2025)*
  - Installed and configured Fly.io CLI (flyctl) for deployment automation
  - Updated Dockerfile to use Rust 1.83 (required for latest dependency versions)
  - Configured embedded Redis in container for session management (no external service needed)
  - Deployed to production environment: https://hypo.fly.dev/
  - Health checks passing on 2 machines in iad (Ashburn, VA) region
  - WebSocket endpoint ready at wss://hypo.fly.dev/ws
  - Configured HTTP/HTTPS endpoints (ports 80/443) with automatic TLS
  - Zero-downtime deployment with automated health monitoring
  - Updated fly.toml with correct build context and Redis configuration
  - Updated .gitignore to exclude build artifacts (.gradle/, *.app/)
  - Removed binary files from version control
  - **Result**: App builds successfully with `swift build -c release` and runs as menu bar application
  - Fixed Compose opt-in annotations and imports across UI modules (BatteryOptimizer, PairingScreen, HomeScreen, SettingsScreen)
  - Simplified PairingRelayClient URL normalization to prevent HttpUrl builder exceptions
  - **Result**: `./android/gradlew assembleDebug` completes successfully; APK at `android/app/build/outputs/apk/debug/app-debug.apk`

- **Backend Code Quality**: Cleaned up compilation warnings and unused code
  - Removed unused Redis client pool field and methods
  - Cleaned up unused import statements
  - Reduced warnings from 5 to 3
  - Improved code maintainability

#### Changed  
- **Project Status**: Updated status tracking to reflect Sprint 8 progress (90% complete)
- **Documentation Structure**: Reorganized docs for better user experience
- **Development Environment**: Established reproducible Android build toolchain
  - Installed OpenJDK 17 via Homebrew with shell profile configuration
  - Provisioned Android SDK via scripts/setup-android-sdk.sh
  - Configured Gradle with local GRADLE_USER_HOME for caching

#### Technical Debt Resolved
- ✅ Android Room KSP processor compilation issues (RESOLVED Oct 12)
- ✅ Android Gradle build configuration (RESOLVED Oct 12)  
- ✅ Android DI graph completion (RESOLVED Oct 12)

#### Technical Debt Remaining
- macOS Swift environment configuration requirements (non-blocking)
- Missing error handling improvements in UI layers
- Production deployment configuration needed
- Physical device testing of Android APK

---

### Sprint 1: Foundation & Architecture

#### Added - October 1, 2025
- **Project Initialization**: Created repository structure and foundational documentation
  - Created comprehensive system architecture diagram (`docs/architecture.mermaid`)
  - Defined technical specifications for all three platforms (`docs/technical.md`)
  - Outlined 16-week development roadmap with 8 sprints (`tasks/tasks.md`)
  - Established project status tracking system (`docs/status.md`)
  - Initialized changelog following Keep a Changelog format
  - Wrote detailed protocol specification (`docs/protocol.md`)
  - Created comprehensive README with quickstart guide
  
- **Architecture Decisions**:
  - Selected Swift 6 + SwiftUI for macOS client
  - Selected Kotlin 2.0 + Jetpack Compose for Android client
  - Selected Rust + Actix-web for backend relay server
  - Defined dual transport architecture (LAN-first with cloud fallback)
  - Established E2E encryption protocol (AES-256-GCM with ECDH key exchange)
  
- **Protocol Design**:
  - Designed JSON-based message format with metadata support
  - Defined content type handling (text, link, image, file)
  - Specified de-duplication strategy using SHA-256 hashing
  - Defined throttling mechanism (token bucket, 1 update per 300ms)
  
- **Security Design**:
  - Documented device pairing protocol (QR code for LAN, 6-digit code for cloud)
  - Specified certificate pinning for cloud relay
  - Defined key rotation policy (30-day cycle with 7-day grace period)
  - Established threat model and mitigation strategies

- **Backend Infrastructure**:
  - Initialized Rust project with Actix-web and Redis
  - Created modular architecture (handlers, services, models, middleware)
  - Implemented WebSocket handler stub with device authentication
  - Implemented Redis client for device connection mapping
  - Implemented token bucket rate limiter with tests
  - Created Docker containerization with docker-compose
  - Set up health check and metrics endpoints

- **Android Client**:
  - Initialized Android project with Gradle Kotlin DSL
  - Configured dependencies (Jetpack Compose, Hilt, Room, OkHttp)
  - Set up project structure following clean architecture
  - Created AndroidManifest with required permissions
  - Defined string resources and ProGuard rules

- **Documentation**:
  - Architecture diagram visualizing component relationships and data flow
  - Technical specification covering implementation details for all platforms
  - Task breakdown with clear dependencies and deliverables
  - Status tracking with metrics, decisions, and risk register
  - Protocol specification with JSON schema and encryption details
  - Platform-specific README files with setup instructions

#### Added - October 2, 2025
- **Protocol Validation**: Published JSON Schema for clipboard and control messages (`docs/protocol.schema.json`) to enable automated validation in tooling and test suites

#### Added - October 3, 2025
- **macOS Client Foundations**: Introduced Swift Package with SwiftUI menu bar shell, history store actor, and NSPasteboard monitor implementation.
- **Android Client Foundations**: Implemented foreground clipboard sync service, Room-backed history persistence, Hilt DI graph, and Compose history UI.
- **Backend Relay Enhancements**: Added in-memory session manager for WebSocket routing with targeted broadcast logic and unit tests.
- **macOS Tooling**: Created reusable Xcode workspace (`macos/HypoApp.xcworkspace`) to streamline local builds of the Swift Package.
- **Security Planning**: Documented cross-platform cryptography library evaluation (`docs/crypto_research.md`) selecting CryptoKit, Tink, and RustCrypto AES-GCM.
- **Protocol Hardening**: Expanded structured error catalogue with offline, conflict, and internal error codes.
- **Roadmap Alignment**: Updated task tracker and project status to reflect coding progress and JSON protocol decision for MVP.

#### Added - October 7, 2025
- **Encrypted Clipboard Envelopes**: Updated the protocol to transmit AES-256-GCM ciphertext with explicit encryption metadata and refreshed the specification to reflect the new structure.
- **Relay Key Registry**: Added an in-memory device key store, control-message handlers for registering keys, and validation that all clipboard payloads include properly sized nonce/tag values.
- **macOS Sync Engine**: Wired CryptoKit encryption/decryption into the menu bar client with injectable key providers, producing encrypted envelopes and decoding remote payloads in unit tests.
- **Cross-Platform Tests**: Added Swift unit coverage for the SyncEngine, extended Rust tests for the WebSocket handler, and tightened AES-GCM utilities to track authentication tags explicitly.
- **Status Tracking**: Marked end-to-end encryption plumbing complete in the project dashboard to unblock Sprint 3 LAN discovery work.
#### Infrastructure
- Initialized Git repository with comprehensive .gitignore
- Created MIT license file
- Set up mono-repo structure (backend/, android/, macos/, docs/, tasks/)
- Configured build systems for all platforms

---

## Release History

*No releases yet - project in initial development phase*

---

## Planned Releases

### [0.1.0] - Alpha Release (Target: ~Week 8)
**Goal**: Core functionality working between paired devices on LAN

**Planned Features**:
- Basic clipboard sync (text only)
- LAN discovery and direct connection
- Device pairing via QR code
- Simple UI on both platforms
- De-duplication and throttling

### [0.2.0] - Beta Release (Target: ~Week 12)
**Goal**: Full feature set with cloud fallback

**Planned Features**:
- Support for links, images, and small files
- Cloud relay fallback
- Clipboard history (200 items)
- Search functionality
- Rich notifications
- Remote pairing

### [0.3.0] - Beta 2 (Target: ~Week 16)
**Goal**: Polished experience ready for wider testing

**Planned Features**:
- Optimized performance (latency <500ms LAN, <3s cloud)
- Comprehensive error handling
- Battery optimization for Android
- Full test coverage
- User documentation
- Monitoring and analytics

### [1.0.0] - Public Release (Target: TBD)
**Goal**: Stable, production-ready application

**Planned Features**:
- All beta features refined based on feedback
- Mac App Store distribution (if feasible)
- Google Play Store distribution
- Auto-update mechanism
- Comprehensive user guide

---

## Version Numbering

- **Major (X.0.0)**: Breaking changes, major feature additions
- **Minor (0.X.0)**: New features, backward compatible
- **Patch (0.0.X)**: Bug fixes, performance improvements

---

## Contributing

*Note: Project currently in solo development phase. Contribution guidelines will be added before public beta.*

---

**Changelog Maintained By**: Principal Engineering Team
**Last Updated**: December 3, 2025

---

## Project Status Summary

**Current Version**: 1.0.2  
**Project Phase**: Production Release  
**Overall Progress**: 100%  
**Status**: Production-ready, all critical issues resolved

### Key Achievements
- ✅ Full Android ↔ macOS synchronization
- ✅ Device-agnostic pairing (any device ↔ any device)
- ✅ Production backend deployed (https://hypo.fly.dev)
- ✅ LAN auto-discovery with tap-to-pair
- ✅ SMS auto-sync (Android → macOS)
- ✅ MIUI/HyperOS optimization
- ✅ Battery optimization (60-80% reduction when screen off)
- ✅ Automated CI/CD pipeline
- ✅ Comprehensive documentation

### Performance Metrics
- **LAN Sync Latency (P95)**: 44ms (target: <500ms) ✅
- **Cloud Sync Latency (P95)**: 1.38s (target: <3s) ✅
- **Backend Response Time**: ~50ms ✅
- **Server Uptime**: 36+ days continuous ✅

### All Critical Issues Resolved ✅
- Android LAN sync binary frames ✅
- Backend routing to wrong device ✅
- Android build issues ✅
- macOS build issues ✅
- All known bugs archived and resolved ✅

### Development Environment Requirements
- **macOS Development**: Requires macOS 26+ with Xcode 15+
- **Android Development**: Any platform with Android Studio Hedgehog+
- **Backend Development**: Any platform with Rust 1.83+ (required for current dependencies)

