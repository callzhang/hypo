import Foundation

public protocol BonjourPublishing: AnyObject {
    func start(with configuration: BonjourPublisher.Configuration)
    func stop()
    func updateTXTRecord(_ metadata: [String: String])
    var currentConfiguration: BonjourPublisher.Configuration? { get }
    var currentEndpoint: LanEndpoint? { get }
}

#if canImport(Darwin)
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
    private var service: NetService?
    private let queue = DispatchQueue(label: "com.hypo.bonjour.publisher")

    public init() {}

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
            service.setTXTRecord(Self.encodeTXT(configuration.txtRecord))
            service.publish()
            self.service = service
        }
    }

    public func stop() {
        queue.sync {
            service?.stop()
            service = nil
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
