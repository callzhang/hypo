import Foundation

extension String {
    func appendToFile(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = self.data(using: .utf8)!
        
        if FileManager.default.fileExists(atPath: path) {
            let fileHandle = try FileHandle(forWritingTo: url)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        } else {
            try data.write(to: url)
        }
    }
}

extension Int {
    /// Format bytes as KB (kilobytes) with 2 decimal places
    /// Example: 1024 -> "1.00 KB", 1536 -> "1.50 KB"
    var formattedAsKB: String {
        let kb = Double(self) / 1024.0
        return String(format: "%.2f KB", kb)
    }
}
