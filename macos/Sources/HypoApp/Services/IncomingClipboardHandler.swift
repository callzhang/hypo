import Foundation
import AppKit
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(os)
import os
#endif

/// Handles incoming clipboard sync messages from remote devices (e.g., Android).
/// Decodes the encrypted payload and applies it to the system clipboard.
@MainActor
public final class IncomingClipboardHandler {
    private let syncEngine: SyncEngine
    private let historyStore: HistoryStore
    private let dispatcher: ClipboardEventDispatcher
    private let pasteboard: NSPasteboard
    private let frameCodec = TransportFrameCodec()
    private var onEntryAdded: ((ClipboardEntry) async -> Void)?
    
    // Direct callbacks for TransportManager internal needs
    public var onClipboardApplied: ((Int) -> Void)?
    public var onClipboardReceived: ((String, Date) -> Void)?
    
    #if canImport(os)
    private let logger = HypoLogger(category: "incoming")
    #endif
    
    public init(
        syncEngine: SyncEngine,
        historyStore: HistoryStore,
        dispatcher: ClipboardEventDispatcher,
        pasteboard: NSPasteboard = .general,
        onEntryAdded: ((ClipboardEntry) async -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.historyStore = historyStore
        self.dispatcher = dispatcher
        self.pasteboard = pasteboard
        self.onEntryAdded = onEntryAdded
    }
    
    public func setOnEntryAdded(_ callback: @escaping (ClipboardEntry) async -> Void) {
        self.onEntryAdded = callback
    }
    
    /// Handle incoming clipboard data from remote device
    /// - Parameters:
    ///   - data: The clipboard data (frame-encoded)
    ///   - transportOrigin: Whether the message came via LAN or cloud relay
    public func handle(_ data: Data, transportOrigin: TransportOrigin = .lan) async {
        logger.info("📥 [IncomingClipboardHandler] handle() called: \(data.count.formattedAsKB), origin=\(transportOrigin.rawValue)")
        do {
            // Decode envelope to get device info
            let envelope = try frameCodec.decode(data)
            let deviceId = envelope.payload.deviceId  // UUID string (pure UUID)
            let devicePlatform = envelope.payload.devicePlatform  // Platform string
            let deviceName = envelope.payload.deviceName
            let platformString = devicePlatform ?? "unknown"
            logger.info("📦 [IncomingClipboardHandler] Decoded envelope: deviceId=\(deviceId.prefix(8)), deviceName=\(deviceName ?? "nil"), platform=\(platformString)")
            
            // Parse platform string to DevicePlatform enum
            let platform: DevicePlatform? = devicePlatform.flatMap { DevicePlatform(rawValue: $0) }
            
            // Check if message was encrypted (non-empty nonce and tag)
            let isEncrypted = !envelope.payload.encryption.nonce.isEmpty && !envelope.payload.encryption.tag.isEmpty
            
            // Note: We need connectionId to update metadata, but we don't have it here
            // The connectionId is available in TransportManager.server(_:didReceiveClipboardData:from:)
            // So we'll update status via notification instead
            
            // Decode the encrypted clipboard payload - syncEngine.decode expects the full frame data
            // It will decode the envelope, decrypt the ciphertext, and decode the ClipboardPayload
            let payload = try await syncEngine.decode(data)
            
            logger.info("📥 Received clipboard: \(payload.contentType.rawValue) from \(deviceName ?? "unknown")")
            
            // Check if incoming content matches current clipboard - skip if same to avoid unnecessary processing
            if await matchesCurrentClipboard(payload) {
                return
            }
            
            // Add to history FIRST (marked as from remote device) with device info from envelope
            // This ensures the entry is created with the correct origin before ClipboardMonitor detects the change
            // Use envelope timestamp (when message was created on Android) instead of current time
            await addToHistory(payload, deviceId: deviceId, devicePlatform: platform, deviceName: deviceName, isEncrypted: isEncrypted, transportOrigin: transportOrigin, timestamp: envelope.timestamp)
            
            // Apply to system clipboard AFTER adding to history
            // Post notification to update ClipboardMonitor's changeCount to prevent duplicate detection
            _ = await MainActor.run { pasteboard.changeCount }
            try await applyToClipboard(payload)
            let afterChangeCount = await MainActor.run { pasteboard.changeCount }
            
            // Notify dispatcher (multicast) and direct callbacks
            dispatcher.notifyClipboardApplied(changeCount: afterChangeCount)
            onClipboardApplied?(afterChangeCount)
            
            // Notify dispatcher (multicast) and direct callbacks (updates lastSeen)
            dispatcher.notifyClipboardReceived(deviceId: deviceId, timestamp: Date())
            onClipboardReceived?(deviceId, Date())
            
        } catch {
            logger.error("❌ [IncomingClipboardHandler] CLIPBOARD ERROR: \(error.localizedDescription), type: \(String(describing: type(of: error)))")
            #if canImport(os)
            logger.error("❌ CLIPBOARD ERROR: Failed to handle incoming clipboard: \(error.localizedDescription)")
            #endif
            if let decodingError = error as? DecodingError {
                logger.info("❌ [IncomingClipboardHandler] DecodingError details: \(decodingError)")
            }
        }
    }
    
    /// Check if incoming payload matches current clipboard content
    private func matchesCurrentClipboard(_ payload: ClipboardPayload) async -> Bool {
        await MainActor.run {
            guard let types = pasteboard.types else { return false }
            
            switch payload.contentType {
            case .text:
                guard types.contains(.string), let currentText = pasteboard.string(forType: .string) else {
                    return false
                }
                let incomingText = String(data: payload.data, encoding: .utf8) ?? ""
                return currentText == incomingText
                
            case .link:
                guard types.contains(.string), let currentUrlString = pasteboard.string(forType: .string) else {
                    return false
                }
                let incomingUrlString = String(data: payload.data, encoding: .utf8) ?? ""
                return currentUrlString == incomingUrlString
                
            case .image:
                // For images, check if pasteboard contains any image type
                // NSImage can handle all formats, so check if we can read an image
                let imageObjects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil).compactMap { $0 as? NSImage }
                guard !imageObjects.isEmpty else {
                    return false
                }
                // If clipboard has image and incoming is image, assume different (could enhance with hash comparison)
                return false
                
            case .file:
                // Files are more complex, skip comparison for now
                return false
            }
        }
    }
    
    private func applyToClipboard(_ payload: ClipboardPayload) async throws {
        // Size check: prevent copying very large items
        let MAX_COPY_SIZE_BYTES = SizeConstants.maxCopySizeBytes
        if payload.data.count > MAX_COPY_SIZE_BYTES {
            let sizeMB = Double(payload.data.count) / (1024.0 * 1024.0)
            let limitMB = Double(MAX_COPY_SIZE_BYTES) / (1024.0 * 1024.0)
            #if canImport(os)
            logger.warning("⚠️ Item too large to copy: \(String(format: "%.1f", sizeMB)) MB (limit: \(String(format: "%.0f", limitMB)) MB)")
            #endif
            // Show notification to user
            await showSizeLimitNotification(itemType: payload.contentType == .image ? "Image" : "File", sizeMB: sizeMB, limitMB: limitMB)
            throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Item too large to copy: \(String(format: "%.1f", sizeMB)) MB exceeds \(String(format: "%.0f", limitMB)) MB limit"])
        }
        
        _ = await MainActor.run {
            pasteboard.clearContents()
        }
        
        switch payload.contentType {
        case .text:
            let text = String(data: payload.data, encoding: .utf8) ?? ""
            _ = await MainActor.run {
                pasteboard.setString(text, forType: .string)
            }
            
            #if canImport(os)
            logger.info("✅ Applied text to clipboard (\(text.count) chars)")
            #endif
            
        case .link:
            let urlString = String(data: payload.data, encoding: .utf8) ?? ""
            _ = await MainActor.run {
                pasteboard.setString(urlString, forType: .string)
            }
            
            #if canImport(os)
            logger.info("✅ Applied link to clipboard: \(urlString)")
            #endif
            
        case .image:
            guard let image = NSImage(data: payload.data) else {
                throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from data"])
            }
            _ = await MainActor.run {
                pasteboard.writeObjects([image])
            }
            
            #if canImport(os)
            logger.info("✅ Applied image to clipboard")
            #endif
            
        case .file:
            // Save file data to temporary location and add to clipboard
            let fileName = payload.metadata?["file_name"] ?? "file"
            let tempDir = FileManager.default.temporaryDirectory
            let fileExtension = (fileName as NSString).pathExtension
            let baseFileName = (fileName as NSString).deletingPathExtension
            // Use UUID to ensure unique filename and prevent conflicts
            let uniqueFileName = "hypo_\(UUID().uuidString)_\(fileExtension.isEmpty ? baseFileName : "\(baseFileName).\(fileExtension)")"
            let tempURL = tempDir.appendingPathComponent(uniqueFileName)
            
            // Write data to temp file
            do {
                try payload.data.write(to: tempURL)
                
                // Register temp file for automatic cleanup
                TempFileManager.shared.registerTempFile(tempURL)
                
                // Add file URL to clipboard
                await MainActor.run {
                    pasteboard.clearContents()
                    pasteboard.writeObjects([tempURL as NSURL])
                }
                
                #if canImport(os)
                logger.info("✅ Applied file to clipboard: \(fileName) (\(payload.data.count.formattedAsKB))")
                #endif
            } catch {
                throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to write file to temporary location: \(error.localizedDescription)"])
            }
        }
    }
    
    private func showSizeLimitNotification(itemType: String, sizeMB: Double, limitMB: Double) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Item Too Large"
        content.body = String(format: "Item (%.1f MB) exceeds the maximum copy limit of %.0f MB. Please use a smaller %@.", sizeMB, limitMB, itemType.lowercased())
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
        #endif
    }
    
    private func addToHistory(_ payload: ClipboardPayload, deviceId: String, devicePlatform: DevicePlatform?, deviceName: String?, isEncrypted: Bool, transportOrigin: TransportOrigin, timestamp: Date) async {
        let finalDeviceId = deviceId  // UUID string (pure UUID)
        let finalPlatform = devicePlatform
        let finalDeviceName = deviceName ?? "Remote Device"
        
        let content: ClipboardContent
        switch payload.contentType {
        case .text:
            let text = String(data: payload.data, encoding: .utf8) ?? ""
            content = .text(text)
            
        case .link:
            let urlString = String(data: payload.data, encoding: .utf8) ?? ""
            if let url = URL(string: urlString) {
                content = .link(url)
            } else {
                content = .text(urlString)
            }
            
        case .image:
            // Extract filename from metadata if available
            let fileName = payload.metadata?["file_name"]
            
            // Try to get actual image dimensions from the image data
            var pixelSize = CGSizeValue(width: 0, height: 0)
            if let image = NSImage(data: payload.data) {
                let size = image.size
                pixelSize = CGSizeValue(width: Int(size.width), height: Int(size.height))
            }
            
            // Extract format from metadata - log warning if missing (should be required in protocol)
            let format: String
            if let metadataFormat = payload.metadata?["format"], !metadataFormat.isEmpty {
                format = metadataFormat
            } else {
                #if canImport(os)
                logger.warning("⚠️ [IncomingClipboardHandler] Image format missing from metadata, defaulting to 'png'. This indicates a protocol issue.")
                #endif
                // TODO: Make format required in protocol
                format = "png"
            }
            
            // Save to disk
            let extensionName = format
            let localPath = try? StorageManager.shared.save(payload.data, extension: extensionName)
            
            let metadata = ImageMetadata(
                pixelSize: pixelSize,
                byteSize: payload.data.count,
                format: format,
                altText: fileName, // Include filename from metadata
                data: payload.data,
                thumbnail: nil,
                localPath: localPath
            )
            content = .image(metadata)
            
        case .file:
            let fileName = payload.metadata?["file_name"] ?? "file"
            // Save to disk
            // Use file extension from name if possible
            let ext = (fileName as NSString).pathExtension
            let localPath = try? StorageManager.shared.save(payload.data, extension: ext.isEmpty ? "dat" : ext)
            
            let metadata = FileMetadata(
                fileName: fileName,
                byteSize: payload.data.count,
                uti: "public.data",
                url: nil,
                base64: payload.data.base64EncodedString(),
                localPath: localPath
            )
            content = .file(metadata)
        }
        
        let entry = ClipboardEntry(
            id: UUID(),
            timestamp: timestamp,  // Use envelope timestamp (when message was created on Android) instead of current time
            deviceId: finalDeviceId,
            originPlatform: finalPlatform,
            originDeviceName: finalDeviceName,
            content: content,
            isPinned: false,
            isEncrypted: isEncrypted,
            transportOrigin: transportOrigin
        )
        
        let (_, _) = await historyStore.insert(entry)
        // Notify callback if provided (e.g., to update viewModel)
        if let onEntryAdded = onEntryAdded {
            await onEntryAdded(entry)
        }
    }
}
