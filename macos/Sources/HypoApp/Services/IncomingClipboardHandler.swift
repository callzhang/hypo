import Foundation
import AppKit
#if canImport(os)
import os
#endif

/// Handles incoming clipboard sync messages from remote devices (e.g., Android).
/// Decodes the encrypted payload and applies it to the system clipboard.
@MainActor
public final class IncomingClipboardHandler {
    private let syncEngine: SyncEngine
    private let historyStore: HistoryStore
    private let pasteboard: NSPasteboard
    private let frameCodec = TransportFrameCodec()
    private var onEntryAdded: ((ClipboardEntry) async -> Void)?
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "incoming")
    #endif
    
    public init(
        syncEngine: SyncEngine,
        historyStore: HistoryStore,
        pasteboard: NSPasteboard = .general,
        onEntryAdded: ((ClipboardEntry) async -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.historyStore = historyStore
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
        let receivedMsg = "📥 [IncomingClipboardHandler] CLIPBOARD RECEIVED: \(data.count) bytes, origin: \(transportOrigin.rawValue)\n"
        print(receivedMsg)
        try? receivedMsg.appendToFile(path: "/tmp/hypo_debug.log")
        do {
            #if canImport(os)
            logger.info("📥 CLIPBOARD RECEIVED: Processing incoming clipboard data (\(data.count) bytes)")
            #endif
            
            // Decode envelope to get device info
            let envelope = try frameCodec.decode(data)
            let deviceId = envelope.payload.deviceId  // UUID string (pure UUID)
            let devicePlatform = envelope.payload.devicePlatform  // Platform string
            let deviceName = envelope.payload.deviceName
            
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
            
            #if canImport(os)
            logger.info("📋 Envelope decoded: from device \(deviceId), name: \(deviceName ?? "unknown")")
            #endif
            let decodedMsg = "📋 [IncomingClipboardHandler] Envelope decoded: deviceId=\(deviceId), deviceName=\(deviceName ?? "unknown")\n"
            print(decodedMsg)
            try? decodedMsg.appendToFile(path: "/tmp/hypo_debug.log")
            #if canImport(os)
            logger.info("✅ CLIPBOARD DECODED: type=\(payload.contentType.rawValue)")
            #endif
            let typeMsg = "✅ [IncomingClipboardHandler] CLIPBOARD DECODED: type=\(payload.contentType.rawValue)\n"
            print(typeMsg)
            try? typeMsg.appendToFile(path: "/tmp/hypo_debug.log")
            
            // Check if incoming content matches current clipboard - skip if same to avoid unnecessary processing
            if await matchesCurrentClipboard(payload) {
                let skipMsg = "⏭️ [IncomingClipboardHandler] Skipping - incoming content matches current clipboard\n"
                print(skipMsg)
                try? skipMsg.appendToFile(path: "/tmp/hypo_debug.log")
                #if canImport(os)
                logger.info("⏭️ Skipping - incoming content matches current clipboard")
                #endif
                return
            }
            
            // Add to history FIRST (marked as from remote device) with device info from envelope
            // This ensures the entry is created with the correct origin before ClipboardMonitor detects the change
            await addToHistory(payload, deviceId: deviceId, devicePlatform: platform, deviceName: deviceName, isEncrypted: isEncrypted, transportOrigin: transportOrigin)
            
            // Apply to system clipboard AFTER adding to history
            // Post notification to update ClipboardMonitor's changeCount to prevent duplicate detection
            let beforeChangeCount = await MainActor.run { pasteboard.changeCount }
            try await applyToClipboard(payload)
            let afterChangeCount = await MainActor.run { pasteboard.changeCount }
            
            // Notify ClipboardMonitor to update its changeCount
            NotificationCenter.default.post(
                name: NSNotification.Name("ClipboardAppliedFromRemote"),
                object: nil,
                userInfo: ["changeCount": afterChangeCount]
            )
            
            // Notify that clipboard was received from this device (updates lastSeen)
            NotificationCenter.default.post(
                name: NSNotification.Name("ClipboardReceivedFromDevice"),
                object: nil,
                userInfo: ["deviceId": deviceId]
            )
            
        } catch {
            let errorMsg = "❌ [IncomingClipboardHandler] CLIPBOARD ERROR: \(error.localizedDescription), type: \(String(describing: type(of: error)))\n"
            print(errorMsg)
            try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
            #if canImport(os)
            logger.error("❌ CLIPBOARD ERROR: Failed to handle incoming clipboard: \(error.localizedDescription)")
            #endif
            if let decodingError = error as? DecodingError {
                print("❌ [IncomingClipboardHandler] DecodingError details: \(decodingError)")
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
        await MainActor.run {
            pasteboard.clearContents()
        }
        
        switch payload.contentType {
        case .text:
            let text = String(data: payload.data, encoding: .utf8) ?? ""
            await MainActor.run {
                pasteboard.setString(text, forType: .string)
            }
            
            #if canImport(os)
            logger.info("✅ Applied text to clipboard (\(text.count) chars)")
            #endif
            
        case .link:
            let urlString = String(data: payload.data, encoding: .utf8) ?? ""
            await MainActor.run {
                pasteboard.setString(urlString, forType: .string)
            }
            
            #if canImport(os)
            logger.info("✅ Applied link to clipboard: \(urlString)")
            #endif
            
        case .image:
            guard let image = NSImage(data: payload.data) else {
                throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from data"])
            }
            await MainActor.run {
                pasteboard.writeObjects([image])
            }
            
            #if canImport(os)
            logger.info("✅ Applied image to clipboard")
            #endif
            
        case .file:
            throw NSError(domain: "IncomingClipboardHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "File clipboard type not yet supported"])
        }
    }
    
    private func addToHistory(_ payload: ClipboardPayload, deviceId: String, devicePlatform: DevicePlatform?, deviceName: String?, isEncrypted: Bool, transportOrigin: TransportOrigin) async {
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
            let metadata = ImageMetadata(
                pixelSize: CGSizeValue(width: 0, height: 0),
                byteSize: payload.data.count,
                format: "png",
                altText: nil,
                data: payload.data,
                thumbnail: nil
            )
            content = .image(metadata)
            
        case .file:
            let fileName = payload.metadata?["file_name"] ?? "file"
            let metadata = FileMetadata(
                fileName: fileName,
                byteSize: payload.data.count,
                uti: "public.data",
                url: nil,
                base64: payload.data.base64EncodedString()
            )
            content = .file(metadata)
        }
        
        let entry = ClipboardEntry(
            id: UUID(),
            timestamp: Date(),
            originDeviceId: finalDeviceId,
            originPlatform: finalPlatform,
            originDeviceName: finalDeviceName,
            content: content,
            isPinned: false,
            isEncrypted: isEncrypted,
            transportOrigin: transportOrigin
        )
        
        let insertedEntries = await historyStore.insert(entry)
        let insertMsg = "✅ [IncomingClipboardHandler] Added to history: \(finalDeviceName) (id: \(finalDeviceId.prefix(8))), total entries: \(insertedEntries.count)\n"
        print(insertMsg)
        try? insertMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        // Notify callback if provided (e.g., to update viewModel)
        if let onEntryAdded = onEntryAdded {
            let callbackMsg = "📞 [IncomingClipboardHandler] Calling onEntryAdded callback\n"
            print(callbackMsg)
            try? callbackMsg.appendToFile(path: "/tmp/hypo_debug.log")
            await onEntryAdded(entry)
            let callbackDoneMsg = "✅ [IncomingClipboardHandler] onEntryAdded callback completed\n"
            print(callbackDoneMsg)
            try? callbackDoneMsg.appendToFile(path: "/tmp/hypo_debug.log")
        } else {
            let noCallbackMsg = "⚠️ [IncomingClipboardHandler] onEntryAdded callback is nil!\n"
            print(noCallbackMsg)
            try? noCallbackMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        
        #if canImport(os)
        logger.info("✅ Added to history from device: \(finalDeviceName) (id: \(finalDeviceId)), total: \(insertedEntries.count)")
        #endif
    }
}

