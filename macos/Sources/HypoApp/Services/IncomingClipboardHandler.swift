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
    public func handle(_ data: Data) async {
        do {
            #if canImport(os)
            logger.info("📥 CLIPBOARD RECEIVED: Processing incoming clipboard data (\(data.count) bytes)")
            #endif
            print("📥 [IncomingClipboardHandler] CLIPBOARD RECEIVED: \(data.count) bytes")
            
            // Decode envelope to get device info
            let envelope = try frameCodec.decode(data)
            let deviceId = envelope.payload.deviceId
            let deviceName = envelope.payload.deviceName
            
            // Note: We need connectionId to update metadata, but we don't have it here
            // The connectionId is available in TransportManager.server(_:didReceiveClipboardData:from:)
            // So we'll update status via notification instead
            
            // Decode the encrypted clipboard payload - syncEngine.decode expects the full frame data
            // It will decode the envelope, decrypt the ciphertext, and decode the ClipboardPayload
            let payload = try await syncEngine.decode(data)
            
            #if canImport(os)
            logger.info("📋 Envelope decoded: from device \(deviceId), name: \(deviceName ?? "unknown")")
            #endif
            print("📋 [IncomingClipboardHandler] Envelope decoded: deviceId=\(deviceId), deviceName=\(deviceName ?? "unknown")")
            
            #if canImport(os)
            logger.info("✅ CLIPBOARD DECODED: type=\(payload.contentType.rawValue)")
            #endif
            print("✅ [IncomingClipboardHandler] CLIPBOARD DECODED: type=\(payload.contentType.rawValue)")
            
            // Apply to system clipboard
            try await applyToClipboard(payload)
            
            // Add to history (marked as from remote device) with device info from envelope
            await addToHistory(payload, deviceId: deviceId, deviceName: deviceName)
            
            // Notify that clipboard was received from this device (updates lastSeen)
            NotificationCenter.default.post(
                name: NSNotification.Name("ClipboardReceivedFromDevice"),
                object: nil,
                userInfo: ["deviceId": deviceId]
            )
            
        } catch {
            #if canImport(os)
            logger.error("❌ CLIPBOARD ERROR: Failed to handle incoming clipboard: \(error.localizedDescription)")
            #endif
            print("❌ [IncomingClipboardHandler] CLIPBOARD ERROR: \(error.localizedDescription)")
            print("❌ [IncomingClipboardHandler] Error type: \(String(describing: type(of: error)))")
            if let decodingError = error as? DecodingError {
                print("❌ [IncomingClipboardHandler] DecodingError details: \(decodingError)")
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
    
    private func addToHistory(_ payload: ClipboardPayload, deviceId: String, deviceName: String?) async {
        let finalDeviceId = deviceId
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
            originDeviceName: finalDeviceName,
            content: content,
            isPinned: false
        )
        
        _ = await historyStore.insert(entry)
        
        // Notify callback if provided (e.g., to update viewModel)
        if let onEntryAdded = onEntryAdded {
            await onEntryAdded(entry)
        }
        
        #if canImport(os)
        logger.info("✅ Added to history from device: \(finalDeviceName) (id: \(finalDeviceId))")
        #endif
        print("✅ [IncomingClipboardHandler] Added to history: \(finalDeviceName) (id: \(finalDeviceId.prefix(8)))")
    }
}

