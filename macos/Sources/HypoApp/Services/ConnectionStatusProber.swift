import Foundation

@MainActor
public final class ConnectionStatusProber {
    public struct Configuration {
        public var pollInterval: TimeInterval
        public var offlineGracePeriod: TimeInterval

        public init(pollInterval: TimeInterval = 15, offlineGracePeriod: TimeInterval = 120) {
            self.pollInterval = max(1, pollInterval)
            self.offlineGracePeriod = max(1, offlineGracePeriod)
        }
    }

    private let configuration: Configuration
    private let notificationCenter: NotificationCenter
    private let dateProvider: () -> Date
    private var probeTask: Task<Void, Never>?
    private var lastSeenByDevice: [String: Date] = [:]
    private var serviceToDeviceId: [String: String] = [:]
    private var publishedState: [String: Bool] = [:]
    private var manualOverrides: [String: Bool] = [:]

    public init(
        configuration: Configuration = .init(),
        notificationCenter: NotificationCenter = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.notificationCenter = notificationCenter
        self.dateProvider = dateProvider
    }

    deinit {
        stop()
    }

    public func start() {
        guard probeTask == nil else { return }
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    public func recordLanPeerAdded(_ peer: DiscoveredPeer) {
        guard let deviceId = Self.deviceId(from: peer.endpoint.metadata) else { return }
        serviceToDeviceId[peer.serviceName] = deviceId
        lastSeenByDevice[deviceId] = peer.lastSeen
        manualOverrides.removeValue(forKey: deviceId)
        publishIfNeeded(deviceId: deviceId, isOnline: true)
    }

    public func recordLanPeerRemoved(serviceName: String) {
        guard let deviceId = serviceToDeviceId.removeValue(forKey: serviceName) else { return }
        lastSeenByDevice[deviceId] = lastSeenByDevice[deviceId] ?? dateProvider()
    }

    public func recordActivity(deviceId: String, timestamp: Date? = nil) {
        let activityTime = timestamp ?? dateProvider()
        lastSeenByDevice[deviceId] = activityTime
        manualOverrides.removeValue(forKey: deviceId)
        publishIfNeeded(deviceId: deviceId, isOnline: true)
    }

    public func publishImmediateStatus(deviceId: String, isOnline: Bool) {
        if isOnline {
            manualOverrides.removeValue(forKey: deviceId)
            lastSeenByDevice[deviceId] = dateProvider()
        } else {
            manualOverrides[deviceId] = false
            if lastSeenByDevice[deviceId] == nil {
                lastSeenByDevice[deviceId] = .distantPast
            }
        }
        publishIfNeeded(deviceId: deviceId, isOnline: isOnline)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            evaluateStatuses()
            let nanoseconds = UInt64(configuration.pollInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private func evaluateStatuses() {
        let now = dateProvider()
        for (deviceId, lastSeen) in lastSeenByDevice {
            let elapsed = now.timeIntervalSince(lastSeen)
            let inferredOnline = elapsed <= configuration.offlineGracePeriod
            let effectiveState = manualOverrides[deviceId] ?? inferredOnline
            publishIfNeeded(deviceId: deviceId, isOnline: effectiveState)
        }
    }

    private func publishIfNeeded(deviceId: String, isOnline: Bool) {
        guard publishedState[deviceId] != isOnline else { return }
        publishedState[deviceId] = isOnline
        notificationCenter.post(
            name: NSNotification.Name("DeviceConnectionStatusChanged"),
            object: nil,
            userInfo: [
                "deviceId": deviceId,
                "isOnline": isOnline
            ]
        )
    }

    private static func deviceId(from metadata: [String: String]) -> String? {
        metadata["device_id"] ?? metadata["deviceId"]
    }
}
