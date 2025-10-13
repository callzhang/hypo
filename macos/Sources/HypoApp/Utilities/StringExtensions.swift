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

