import Foundation
#if canImport(os)
import os
#endif

/// A SyncTransport that sends to both LAN and cloud simultaneously for maximum reliability.
/// At least one transport must succeed, but both are attempted in parallel.
/// When sending encrypted messages, creates separate envelopes with unique nonces for each transport
/// to prevent nonce reuse (AES-GCM requires unique nonces per encryption with the same key).
@MainActor
public final class DualSyncTransport: SyncTransport {
    private let lanTransport: SyncTransport
    private let cloudTransport: SyncTransport
    private var cryptoService: CryptoService?
    private var keyProvider: DeviceKeyProviding?
    
    #if canImport(os)
    private let logger = HypoLogger(category: "dual-transport")
    #endif
    
    public init(lanTransport: SyncTransport, cloudTransport: SyncTransport, cryptoService: CryptoService? = nil, keyProvider: DeviceKeyProviding? = nil) {
        self.lanTransport = lanTransport
        self.cloudTransport = cloudTransport
        self.cryptoService = cryptoService
        self.keyProvider = keyProvider
    }
    
    /// Configure crypto service and key provider for creating separate envelopes with unique nonces
    public func configure(cryptoService: CryptoService, keyProvider: DeviceKeyProviding) {
        self.cryptoService = cryptoService
        self.keyProvider = keyProvider
    }
    
    public func connect() async throws {
        // Connect both transports in parallel
        async let lanConnect: Void = lanTransport.connect()
        async let cloudConnect: Void = cloudTransport.connect()
        
        // Wait for both, but don't fail if one fails
        do {
            try await lanConnect
            logger.debug("✅ [DualSyncTransport] LAN connected")
        } catch {
            logger.info("⚠️ [DualSyncTransport] LAN transport connect failed: \(error.localizedDescription)")
        }
        
        do {
            try await cloudConnect
            logger.debug("✅ [DualSyncTransport] Cloud connected")
        } catch {
            logger.info("⚠️ [DualSyncTransport] Cloud transport connect failed: \(error.localizedDescription)")
        }
    }
    
    public func send(_ envelope: SyncEnvelope) async throws {
        
        // Check if this is an encrypted message (has nonce and tag)
        let isEncrypted = !envelope.payload.encryption.nonce.isEmpty && !envelope.payload.encryption.tag.isEmpty
        
        // If encrypted and we have crypto service and key provider, create separate envelopes with unique nonces
        // This prevents nonce reuse when the same message is sent to both LAN and cloud
        if isEncrypted, let cryptoService = cryptoService, let keyProvider = keyProvider, let targetDeviceId = envelope.payload.target {
            // Decrypt the original envelope to get plaintext
            let key = try await keyProvider.key(for: targetDeviceId)
            let aad = Data(envelope.payload.deviceId.utf8)
            let plaintext = try await cryptoService.decrypt(
                ciphertext: envelope.payload.ciphertext,
                key: key,
                nonce: envelope.payload.encryption.nonce,
                tag: envelope.payload.encryption.tag,
                aad: aad
            )
            
            // Create two separate envelopes with unique nonces but same message ID for deduplication
            let messageId = envelope.id
            let timestamp = envelope.timestamp
            
            // First envelope (for LAN) - re-encrypt with new nonce
            let sealed1 = try await cryptoService.encrypt(plaintext: plaintext, key: key, aad: aad)
            let envelope1 = SyncEnvelope(
                id: messageId,  // Same message ID for deduplication
                timestamp: timestamp,
                type: envelope.type,
                payload: .init(
                    contentType: envelope.payload.contentType,
                    ciphertext: sealed1.ciphertext,
                    deviceId: envelope.payload.deviceId,
                    devicePlatform: envelope.payload.devicePlatform,
                    deviceName: envelope.payload.deviceName,
                    target: targetDeviceId,
                    encryption: .init(nonce: sealed1.nonce, tag: sealed1.tag)
                )
            )
            
            // Second envelope (for cloud) - re-encrypt with new nonce
            let sealed2 = try await cryptoService.encrypt(plaintext: plaintext, key: key, aad: aad)
            let envelope2 = SyncEnvelope(
                id: messageId,  // Same message ID for deduplication
                timestamp: timestamp,
                type: envelope.type,
                payload: .init(
                    contentType: envelope.payload.contentType,
                    ciphertext: sealed2.ciphertext,
                    deviceId: envelope.payload.deviceId,
                    devicePlatform: envelope.payload.devicePlatform,
                    deviceName: envelope.payload.deviceName,
                    target: targetDeviceId,
                    encryption: .init(nonce: sealed2.nonce, tag: sealed2.tag)
                )
            )
            
            // Send both envelopes in parallel
            async let lanSend = sendViaLAN(envelope1)
            async let cloudSend = sendViaCloud(envelope2)
            
            // Wait for both to complete
            let (lanResult, cloudResult) = await (lanSend, cloudSend)
            
            // Always send to both - no fallback logic, both are attempted simultaneously
            // Log results but don't throw errors (best-effort dual send)
            switch (lanResult, cloudResult) {
            case (.success, .success):
                logger.debug("✅ [DualSyncTransport] Both succeeded")
            case (.success, .failure):
                logger.info("✅ [DualSyncTransport] LAN transport succeeded (cloud failed, but both were attempted)")
            case (.failure, .success):
                logger.info("✅ [DualSyncTransport] Cloud transport succeeded (LAN failed, but both were attempted)")
            case (.failure(_), .failure(let cloudError)):
                logger.info("❌ [DualSyncTransport] Both LAN and cloud transports failed (but both were attempted)")
                // Throw the cloud error (usually more informative) - but both were attempted
                throw cloudError
            }
        } else {
            // Plain text mode or no crypto service - send same envelope to both (nonce reuse not an issue)
            logger.debug("📡 [DualSyncTransport] Sending same envelope to both transports")
            
            // Send to both transports in parallel
            async let lanSend = sendViaLAN(envelope)
            async let cloudSend = sendViaCloud(envelope)
            
            // Wait for both to complete
            let (lanResult, cloudResult) = await (lanSend, cloudSend)
            
            // Always send to both - no fallback logic, both are attempted simultaneously
            // Log results but don't throw errors (best-effort dual send)
            switch (lanResult, cloudResult) {
            case (.success, .success):
                logger.debug("✅ [DualSyncTransport] Both succeeded")
            case (.success, .failure):
                logger.info("✅ [DualSyncTransport] LAN transport succeeded (cloud failed, but both were attempted)")
            case (.failure, .success):
                logger.info("✅ [DualSyncTransport] Cloud transport succeeded (LAN failed, but both were attempted)")
            case (.failure(_), .failure(let cloudError)):
                logger.info("❌ [DualSyncTransport] Both LAN and cloud transports failed (but both were attempted)")
                // Throw the cloud error (usually more informative) - but both were attempted
                throw cloudError
            }
        }
    }
    
    public func disconnect() async {
        async let lanDisconnect: Void = lanTransport.disconnect()
        async let cloudDisconnect: Void = cloudTransport.disconnect()
        _ = await (lanDisconnect, cloudDisconnect)
    }
    
    private func sendViaLAN(_ envelope: SyncEnvelope) async -> Result<Void, Error> {
        do {
            // Try LAN with timeout (3 seconds)
            return try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
                group.addTask {
                    do {
                        try await self.lanTransport.send(envelope)
                        return Result<Void, Error>.success(())
                    } catch {
                        return Result<Void, Error>.failure(error)
                    }
                }
                
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        return Result<Void, Error>.failure(NSError(
                            domain: "DualSyncTransport",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "LAN transport timeout"]
                        ))
                    } catch {
                        return Result<Void, Error>.failure(error)
                    }
                }
                
                // Wait for first task to complete (either success or timeout)
                let result = try await group.next()!
                // Cancel remaining tasks
                group.cancelAll()
                return result
            }
        } catch {
            logger.info("⚠️ [DualSyncTransport] LAN transport failed: \(error.localizedDescription)")
            return Result<Void, Error>.failure(error)
        }
    }
    
    private func sendViaCloud(_ envelope: SyncEnvelope) async -> Result<Void, Error> {
        do {
            try await cloudTransport.send(envelope)
            return .success(())
        } catch {
            logger.info("⚠️ [DualSyncTransport] Cloud transport failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

