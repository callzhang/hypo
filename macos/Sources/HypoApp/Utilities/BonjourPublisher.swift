import Foundation

@MainActor
public protocol BonjourPublishing: AnyObject, Sendable {
    func start(with configuration: BonjourPublisher.Configuration)
    func stop()
    func updateTXTRecord(_ metadata: [String: String])
    var currentConfiguration: BonjourPublisher.Configuration? { get }
    var currentEndpoint: LanEndpoint? { get }
}

#if canImport(Darwin)
@MainActor
public final class BonjourPublisher: NSObject, BonjourPublishing {
    public struct Configuration: Equatable, Sendable {
        public let domain: String
        public let serviceType: String
        public let serviceName: String
        public let port: Int
        public let version: String
        public let fingerprint: String
        public let protocols: [String]
        public let deviceId: String?
        public let publicKey: String?
        public let signingPublicKey: String?

        public init(
            domain: String = "local.",
            serviceType: String = "_hypo._tcp.",
            serviceName: String,
            port: Int,
            version: String,
            fingerprint: String,
            protocols: [String],
            deviceId: String? = nil,
            publicKey: String? = nil,
            signingPublicKey: String? = nil
        ) {
            self.domain = domain
            self.serviceType = serviceType
            self.serviceName = serviceName
            self.port = port
            self.version = version
            self.fingerprint = fingerprint
            self.protocols = protocols
            self.deviceId = deviceId
            self.publicKey = publicKey
            self.signingPublicKey = signingPublicKey
        }

        public var txtRecord: [String: String] {
            var record: [String: String] = [
                "version": version,
                "protocols": protocols.joined(separator: ",")
            ]
            record["fingerprint_sha256"] = fingerprint
            
            // Add pairing information for LAN auto-discovery
            if let deviceId = deviceId {
                record["device_id"] = deviceId
            }
            if let publicKey = publicKey {
                record["pub_key"] = publicKey
            }
            if let signingPublicKey = signingPublicKey {
                record["signing_pub_key"] = signingPublicKey
            }
            
            return record
        }
    }

    private var configuration: Configuration?
    private var service: NetService?
    private var stopCompletion: (() -> Void)?

    public override init() {
        super.init()
    }

    public var currentConfiguration: Configuration? {
        configuration
    }

    public var currentEndpoint: LanEndpoint? {
        guard let configuration else { return nil }
        let host = ProcessInfo.processInfo.hostName
        return LanEndpoint(
            host: host,
            port: configuration.port,
            deviceId: configuration.deviceId,
            deviceName: configuration.serviceName,
            fingerprint: configuration.fingerprint,
            metadata: configuration.txtRecord
        )
    }

    public func start(with configuration: Configuration) {
        // Now isolated to @MainActor, DispatchQueue.main.async is redundant if called from MainActor.
        // But for safety and consistency with existing code, we can keep it or use Task.
        guard configuration.port > 0 else { return }
        
        self.configuration = configuration
        
        #if canImport(os)
        let logger = HypoLogger(category: "BonjourPublisher")
        logger.info("📢 Starting Bonjour service: \(configuration.serviceName) on port \(configuration.port)")
        #endif
        
        let service = NetService(
            domain: configuration.domain,
            type: configuration.serviceType,
            name: configuration.serviceName,
            port: Int32(configuration.port)
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(Self.encodeTXT(configuration.txtRecord))
        service.publish()
        self.service = service
    }

    public func stop() {
        guard let service = self.service else { return }
        service.delegate = self
        service.stop()
    }
    
    public func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let service = self.service else {
            completion()
            return
        }
        self.stopCompletion = completion
        service.delegate = self
        service.stop()
    }

    public func updateTXTRecord(_ metadata: [String: String]) {
        guard let service = self.service else { return }
        #if canImport(os)
        let logger = HypoLogger(category: "BonjourPublisher")
        logger.debug("📝 Updating TXT record: \(metadata)")
        #endif
        service.setTXTRecord(Self.encodeTXT(metadata))
    }

    private static func encodeTXT(_ record: [String: String]) -> Data {
        #if canImport(os)
        let logger = HypoLogger(category: "BonjourPublisher")
        logger.debug("📝 Encoding TXT record: \(record)")
        #endif
        var dataRecord: [String: Data] = [:]
        for (key, value) in record {
            dataRecord[key] = Data(value.utf8)
        }
        return NetService.data(fromTXTRecord: dataRecord)
    }
}

extension BonjourPublisher: @preconcurrency NetServiceDelegate {
    public func netServiceDidPublish(_ sender: NetService) {
        #if canImport(os)
        let logger = HypoLogger(category: "BonjourPublisher")
        logger.info("✅ Service published: \(sender.name).\(sender.type)\(sender.domain) port:\(sender.port)")
        #endif
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        #if canImport(os)
        let logger = HypoLogger(category: "BonjourPublisher")
        logger.error("❌ Failed to publish service: \(errorDict)")
        #endif
    }

    public func netServiceDidStop(_ sender: NetService) {
        if sender === self.service {
            self.service = nil
            #if canImport(os)
            let logger = HypoLogger(category: "BonjourPublisher")
            logger.info("🛑 Service stopped")
            #endif
            let completion = self.stopCompletion
            self.stopCompletion = nil
            if let completion = completion {
                completion()
            }
        }
    }
}
#else
@MainActor
public final class BonjourPublisher: BonjourPublishing {
    public struct Configuration: Sendable, Equatable {
        public let domain: String
        public let serviceType: String
        public let serviceName: String
        public let port: Int
        public let version: String
        public let fingerprint: String
        public let protocols: [String]
        public let deviceId: String?

        public init(
            domain: String = "local.",
            serviceType: String = "_hypo._tcp.",
            serviceName: String,
            port: Int,
            version: String,
            fingerprint: String,
            protocols: [String],
            deviceId: String? = nil
        ) {
            self.domain = domain
            self.serviceType = serviceType
            self.serviceName = serviceName
            self.port = port
            self.version = version
            self.fingerprint = fingerprint
            self.protocols = protocols
            self.deviceId = deviceId
        }

        public var txtRecord: [String: String] {
            var record: [String: String] = [
                "version": version,
                "protocols": protocols.joined(separator: ",")
            ]
            record["fingerprint_sha256"] = fingerprint
            if let deviceId = deviceId {
                record["device_id"] = deviceId
            }
            return record
        }
    }

    private var configuration: Configuration?

    public init() {}

    public var currentConfiguration: Configuration? { configuration }

    public var currentEndpoint: LanEndpoint? {
        guard let configuration else { return nil }
        let host = ProcessInfo.processInfo.hostName
        return LanEndpoint(
            host: host,
            port: configuration.port,
            deviceId: configuration.deviceId,
            deviceName: configuration.serviceName,
            fingerprint: configuration.fingerprint,
            metadata: configuration.txtRecord
        )
    }

    public func start(with configuration: Configuration) {
        self.configuration = configuration
    }

    public func stop() {
        configuration = nil
    }

    public func updateTXTRecord(_ metadata: [String: String]) {
        guard let configuration else { return }
        let fingerprint = metadata["fingerprint_sha256"] ?? configuration.fingerprint
        let version = metadata["version"] ?? configuration.version
        let protocols = (metadata["protocols"] ?? configuration.protocols.joined(separator: ",")).split(separator: ",").map(String.init)
        self.configuration = Configuration(
            domain: configuration.domain,
            serviceType: configuration.serviceType,
            serviceName: configuration.serviceName,
            port: configuration.port,
            version: version,
            fingerprint: fingerprint,
            protocols: protocols,
            deviceId: configuration.deviceId
        )
    }
}
#endif
