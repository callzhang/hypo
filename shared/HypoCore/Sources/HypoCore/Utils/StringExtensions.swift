import Foundation

extension Int {
    /// Format bytes as KB (kilobytes) with 2 decimal places
    /// Example: 1024 -> "1.00 KB", 1536 -> "1.50 KB"
    public var formattedAsKB: String {
        let kb = Double(self) / 1024.0
        return String(format: "%.2f KB", kb)
    }
}
