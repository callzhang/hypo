import Foundation

public protocol BonjourPublishing: AnyObject {
    func start(with configuration: BonjourPublisher.Configuration)
    func stop()
    func updateTXTRecord(_ metadata: [String: String])
    var currentConfiguration: BonjourPublisher.Configuration? { get }
    var currentEndpoint: LanEndpoint? { get }
}

#if canImport(Darwin)
public final class BonjourPublisher: NSObject, BonjourPublishing {
    public struct Configuration: Equatable {
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
    private let queue = DispatchQueue(label: "com.hypo.bonjour.publisher")
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
            fingerprint: configuration.fingerprint,
            metadata: configuration.txtRecord
        )
    }

    public func start(with configuration: Configuration) {
        queue.sync {
            guard configuration.port > 0 else { return }
            self.configuration = configuration
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
    }

    public func stop() {
        queue.sync {
            guard let service = service else { return }
            service.delegate = self
            service.stop()
            // For synchronous stop, we still wait for delegate but don't block
            // The service will be set to nil in the delegate callback
        }
    }
    
    public func stop(completion: @escaping () -> Void) {
        queue.sync {
            guard let service = service else {
                completion()
                return
            }
            stopCompletion = completion
            service.delegate = self
            service.stop()
            // Don't set service to nil yet - wait for delegate callback
        }
    }

    public func updateTXTRecord(_ metadata: [String: String]) {
        queue.sync(execute: {
            guard let service else { return }
            service.setTXTRecord(Self.encodeTXT(metadata))
        })
    }

    private static func encodeTXT(_ record: [String: String]) -> Data {
        var dataRecord: [String: Data] = [:]
        for (key, value) in record {
            dataRecord[key] = Data(value.utf8)
        }
        return NetService.data(fromTXTRecord: dataRecord)
    }
}

extension BonjourPublisher: NetServiceDelegate {
    public func netServiceDidStop(_ sender: NetService) {
        queue.sync {
            if sender === service {
                service = nil
                let completion = stopCompletion
                stopCompletion = nil
                // Call completion on the queue to ensure it's called after service is nil
                if let completion = completion {
                    completion()
                }
            }
        }
    }
}
#else
public final class BonjourPublisher: BonjourPublishing {
    public struct Configuration: Equatable {
        public let domain: String
        public let serviceType: String
        public let serviceName: String
        public let port: Int
        public let version: String
        public let fingerprint: String
        public let protocols: [String]

        public init(
            domain: String = "local.",
            serviceType: String = "_hypo._tcp.",
            serviceName: String,
            port: Int,
            version: String,
            fingerprint: String,
            protocols: [String]
        ) {
            self.domain = domain
            self.serviceType = serviceType
            self.serviceName = serviceName
            self.port = port
            self.version = version
            self.fingerprint = fingerprint
            self.protocols = protocols
        }

        public var txtRecord: [String: String] {
            var record: [String: String] = [
                "version": version,
                "protocols": protocols.joined(separator: ",")
            ]
            record["fingerprint_sha256"] = fingerprint
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
            protocols: protocols
        )
    }
}
#endif
