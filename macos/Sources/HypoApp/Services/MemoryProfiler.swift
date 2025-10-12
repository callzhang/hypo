import Foundation
import os.log
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif

/// Memory profiler for monitoring and optimizing memory usage in the macOS client
public actor MemoryProfiler {
    
    public struct MemorySnapshot {
        let timestamp: Date
        let residentMemoryMB: Double
        let virtualMemoryMB: Double
        let peakMemoryMB: Double
        let historyCount: Int
        let connectionCount: Int
        let estimatedHistoryMemoryMB: Double
        
        public var totalMemoryMB: Double {
            residentMemoryMB + virtualMemoryMB
        }
        
        public func formatted() -> String {
            """
            Memory Profile [\(DateFormatter.timeFormatter.string(from: timestamp))]:
            - Resident: \(String(format: "%.1f", residentMemoryMB)) MB
            - Virtual: \(String(format: "%.1f", virtualMemoryMB)) MB
            - Peak: \(String(format: "%.1f", peakMemoryMB)) MB
            - History Items: \(historyCount) (~\(String(format: "%.1f", estimatedHistoryMemoryMB)) MB)
            - Connections: \(connectionCount)
            """
        }
    }
    
    private var snapshots: [MemorySnapshot] = []
    private let maxSnapshots: Int
    private var monitoringTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "memory-profiler")
    
    private weak var historyStore: HistoryStore?
    private weak var connectionPool: WebSocketConnectionPool?
    
    public init(
        maxSnapshots: Int = 100,
        historyStore: HistoryStore? = nil,
        connectionPool: WebSocketConnectionPool? = nil
    ) {
        self.maxSnapshots = maxSnapshots
        self.historyStore = historyStore
        self.connectionPool = connectionPool
    }
    
    deinit {
        monitoringTask?.cancel()
    }
    
    // MARK: - Public API
    
    public func startMonitoring(interval: TimeInterval = 30.0) {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.captureSnapshot()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        logger.info("Memory monitoring started with \(interval)s interval")
    }
    
    public func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("Memory monitoring stopped")
    }
    
    public func captureSnapshot() async -> MemorySnapshot {
        let memoryInfo = getMemoryInfo()
        
        let historyCount = await historyStore?.all().count ?? 0
        let estimatedHistoryMemory = await estimateHistoryMemoryUsage()
        let connectionStats = await connectionPool?.getPoolStats()
        
        let snapshot = MemorySnapshot(
            timestamp: Date(),
            residentMemoryMB: memoryInfo.resident / (1024 * 1024),
            virtualMemoryMB: memoryInfo.virtual / (1024 * 1024),
            peakMemoryMB: memoryInfo.peak / (1024 * 1024),
            historyCount: historyCount,
            connectionCount: connectionStats?.active ?? 0,
            estimatedHistoryMemoryMB: estimatedHistoryMemory / (1024 * 1024)
        )
        
        snapshots.append(snapshot)
        
        // Trim snapshots if we exceed the limit
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
        
        // Log warnings for memory issues
        checkForMemoryIssues(snapshot)
        
        return snapshot
    }
    
    public func getLatestSnapshot() -> MemorySnapshot? {
        snapshots.last
    }
    
    public func getAllSnapshots() -> [MemorySnapshot] {
        snapshots
    }
    
    public func getMemoryTrend() -> (averageMB: Double, peakMB: Double, growthRate: Double) {
        guard snapshots.count >= 2 else {
            return (averageMB: 0, peakMB: 0, growthRate: 0)
        }
        
        let totalMemories = snapshots.map(\.totalMemoryMB)
        let averageMB = totalMemories.reduce(0, +) / Double(totalMemories.count)
        let peakMB = totalMemories.max() ?? 0
        
        // Calculate growth rate (MB per hour)
        let firstSnapshot = snapshots.first!
        let lastSnapshot = snapshots.last!
        let timeDiff = lastSnapshot.timestamp.timeIntervalSince(firstSnapshot.timestamp) / 3600 // hours
        let memoryDiff = lastSnapshot.totalMemoryMB - firstSnapshot.totalMemoryMB
        let growthRate = timeDiff > 0 ? memoryDiff / timeDiff : 0
        
        return (averageMB: averageMB, peakMB: peakMB, growthRate: growthRate)
    }
    
    public func generateReport() -> String {
        guard !snapshots.isEmpty else {
            return "No memory data available"
        }
        
        let latest = snapshots.last!
        let trend = getMemoryTrend()
        
        var report = """
        Memory Profile Report
        =====================
        
        Latest Snapshot:
        \(latest.formatted())
        
        Trend Analysis:
        - Average Memory: \(String(format: "%.1f", trend.averageMB)) MB
        - Peak Memory: \(String(format: "%.1f", trend.peakMB)) MB
        - Growth Rate: \(String(format: "%.2f", trend.growthRate)) MB/hour
        
        """
        
        // Add memory efficiency recommendations
        report += generateRecommendations()
        
        return report
    }
    
    public func exportCSV() -> String {
        var csv = "timestamp,resident_mb,virtual_mb,peak_mb,history_count,connection_count,history_memory_mb\n"
        
        for snapshot in snapshots {
            let row = """
            \(snapshot.timestamp.timeIntervalSince1970),\
            \(snapshot.residentMemoryMB),\
            \(snapshot.virtualMemoryMB),\
            \(snapshot.peakMemoryMB),\
            \(snapshot.historyCount),\
            \(snapshot.connectionCount),\
            \(snapshot.estimatedHistoryMemoryMB)
            """
            csv += row + "\n"
        }
        
        return csv
    }
    
    // MARK: - Private Methods
    
    private func getMemoryInfo() -> (resident: Double, virtual: Double, peak: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return (
                resident: Double(info.resident_size),
                virtual: Double(info.virtual_size),
                peak: Double(info.resident_size_max)
            )
        } else {
            logger.error("Failed to get memory info: \(result)")
            return (resident: 0, virtual: 0, peak: 0)
        }
    }
    
    private func estimateHistoryMemoryUsage() async -> Double {
        guard let historyStore = historyStore else { return 0 }
        
        let entries = await historyStore.all()
        return entries.reduce(0) { total, entry in
            total + Double(entry.estimatedMemoryFootprint)
        }
    }
    
    private func checkForMemoryIssues(_ snapshot: MemorySnapshot) {
        // Memory warning thresholds
        let residentWarningMB: Double = 100 // 100 MB
        let growthWarningMBPerHour: Double = 10 // 10 MB/hour
        
        if snapshot.residentMemoryMB > residentWarningMB {
            logger.warning("High memory usage detected: \(snapshot.residentMemoryMB, privacy: .public) MB resident")
        }
        
        let trend = getMemoryTrend()
        if trend.growthRate > growthWarningMBPerHour {
            logger.warning("High memory growth rate detected: \(trend.growthRate, privacy: .public) MB/hour")
        }
        
        // Check memory efficiency
        let historyEfficiency = snapshot.historyCount > 0 ? 
            snapshot.estimatedHistoryMemoryMB / Double(snapshot.historyCount) : 0
        if historyEfficiency > 0.1 { // 100KB per item
            logger.warning("Inefficient memory usage in history: \(historyEfficiency, privacy: .public) MB per item")
        }
    }
    
    private func generateRecommendations() -> String {
        guard let latest = snapshots.last else { return "" }
        
        var recommendations: [String] = []
        
        // High memory usage
        if latest.residentMemoryMB > 50 {
            recommendations.append("• Consider reducing history limit (currently \(latest.historyCount) items)")
        }
        
        // History memory efficiency
        let avgHistoryMemory = latest.historyCount > 0 ? 
            latest.estimatedHistoryMemoryMB / Double(latest.historyCount) : 0
        if avgHistoryMemory > 0.05 { // 50KB per item
            recommendations.append("• History items are using excessive memory - consider optimizing content storage")
        }
        
        // Connection efficiency
        if latest.connectionCount > 5 {
            recommendations.append("• High number of network connections - check connection pooling settings")
        }
        
        // Growth rate
        let trend = getMemoryTrend()
        if trend.growthRate > 5 {
            recommendations.append("• Memory usage is growing rapidly - check for potential memory leaks")
        }
        
        if recommendations.isEmpty {
            recommendations.append("• Memory usage appears optimal")
        }
        
        return "Recommendations:\n" + recommendations.joined(separator: "\n")
    }
}

// MARK: - Extensions

private extension DateFormatter {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// Extension removed - defined in OptimizedHistoryStore.swift to avoid redeclaration