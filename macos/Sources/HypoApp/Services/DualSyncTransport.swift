import Foundation
#if canImport(os)
import os
#endif

/// A SyncTransport that sends to both LAN and cloud simultaneously for maximum reliability.
/// At least one transport must succeed, but both are attempted in parallel.
@MainActor
public final class DualSyncTransport: SyncTransport {
    private let lanTransport: SyncTransport
    private let cloudTransport: SyncTransport
    
    #if canImport(os)
    private let logger = HypoLogger(category: "dual-transport")
    #endif
    
    public init(lanTransport: SyncTransport, cloudTransport: SyncTransport) {
        self.lanTransport = lanTransport
        self.cloudTransport = cloudTransport
    }
    
    public func connect() async throws {
        // Connect both transports in parallel
        async let lanConnect: Void = lanTransport.connect()
        async let cloudConnect: Void = cloudTransport.connect()
        
        // Wait for both, but don't fail if one fails
        do {
            try await lanConnect
            logger.info("✅ [DualSyncTransport] LAN transport connected")
        } catch {
            logger.info("⚠️ [DualSyncTransport] LAN transport connect failed: \(error.localizedDescription)")
        }
        
        do {
            try await cloudConnect
            logger.info("✅ [DualSyncTransport] Cloud transport connected")
        } catch {
            logger.info("⚠️ [DualSyncTransport] Cloud transport connect failed: \(error.localizedDescription)")
        }
    }
    
    public func send(_ envelope: SyncEnvelope) async throws {
        logger.info("📡 [DualSyncTransport] Sending to both LAN and cloud simultaneously...")
        
        // Send to both transports in parallel
        async let lanSend = sendViaLAN(envelope)
        async let cloudSend = sendViaCloud(envelope)
        
        // Wait for both to complete
        let (lanResult, cloudResult) = await (lanSend, cloudSend)
        
        // Always send to both - no fallback logic, both are attempted simultaneously
        // Log results but don't throw errors (best-effort dual send)
        switch (lanResult, cloudResult) {
        case (.success, .success):
            logger.info("✅ [DualSyncTransport] Both LAN and cloud transports succeeded")
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

