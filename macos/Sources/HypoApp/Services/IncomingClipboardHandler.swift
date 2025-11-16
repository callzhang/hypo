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
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "incoming")
    #endif
    
    public init(
        syncEngine: SyncEngine,
        historyStore: HistoryStore,
        pasteboard: NSPasteboard = .general
    ) {
        self.syncEngine = syncEngine
        self.historyStore = historyStore
        self.pasteboard = pasteboard
    }
    
    /// Handle incoming clipboard data from remote device
    public func handle(_ data: Data) async {
        do {
            #if canImport(os)
            logger.info("📥 Processing incoming clipboard data (\(data.count) bytes)")
            #endif
            
            // Decode the encrypted clipboard payload
            let payload = try await syncEngine.decode(data)
            
            #if canImport(os)
            logger.info("✅ Decoded clipboard: type=\(payload.contentType.rawValue)")
            #endif
            
            // Apply to system clipboard
            try await applyToClipboard(payload)
            
            // Add to history (marked as from remote device)
            await addToHistory(payload)
            
        } catch {
            #if canImport(os)
            logger.error("❌ Failed to handle incoming clipboard: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func applyToClipboard(_ payload: ClipboardPayload) async throws {
        pasteboard.clearContents()
        
        switch payload.contentType {
        case .text:
            let text = String(data: payload.data, encoding: .utf8) ?? ""
            pasteboard.setString(text, forType: .string)
            
            #if canImport(os)
            logger.info("✅ Applied text to clipboard (\(text.count) chars)")
            #endif
            
        case .link:
            let urlString = String(data: payload.data, encoding: .utf8) ?? ""
            pasteboard.setString(urlString, forType: .string)
            
            #if canImport(os)
            logger.info("✅ Applied link to clipboard: \(urlString)")
            #endif
            
        case .image:
            if let image = NSImage(data: payload.data) {
                pasteboard.writeObjects([image])
                
                #if canImport(os)
                logger.info("✅ Applied image to clipboard")
                #endif
            }
            
        case .file:
            // File handling would require additional work (temp file creation, etc.)
            #if canImport(os)
            logger.warning("⚠️ File clipboard type not yet supported")
            #endif
        }
    }
    
    private func addToHistory(_ payload: ClipboardPayload) async {
        let deviceId = payload.metadata?["device_id"] ?? "unknown"
        let deviceName = payload.metadata?["device_name"] ?? "Remote Device"
        
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
            originDeviceId: deviceId,
            originDeviceName: deviceName,
            content: content,
            isPinned: false
        )
        
        _ = await historyStore.insert(entry)
        
        #if canImport(os)
        logger.info("✅ Added to history from device: \(deviceName)")
        #endif
    }
}

