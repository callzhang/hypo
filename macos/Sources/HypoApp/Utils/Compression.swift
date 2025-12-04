import Foundation
import Compression
import zlib

public enum CompressionError: Error {
    case compressionFailed
    case decompressionFailed
}

public struct CompressionUtils {
    /// Compress data using gzip (compatible with Java GZIPInputStream)
    /// Always compresses - no threshold check
    /// - Parameter data: Data to compress
    /// - Returns: Gzip-compressed data
    public static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return data
        }
        
        // Use deflate with gzip window bits to produce raw deflate (not zlib-wrapped)
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        stream.avail_in = uInt(data.count)
        stream.next_in = data.withUnsafeBytes { UnsafeMutablePointer(mutating: $0.bindMemory(to: Bytef.self).baseAddress!) }
        
        // Initialize deflate with gzip format (MAX_WBITS + 16)
        // This produces raw deflate without zlib wrapper
        let windowBits = MAX_WBITS + 16  // +16 for gzip format
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            Int32(windowBits),
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        
        guard status == Z_OK else {
            throw CompressionError.compressionFailed
        }
        defer { deflateEnd(&stream) }
        
        // Allocate output buffer (start with reasonable size, will grow if needed)
        var bufferSize = data.count + (data.count / 10) + 16
        var compressedData = Data(count: bufferSize)
        var totalOut: Int = 0
        
        // Compress in a loop until stream is finished
        var finished = false
        while !finished {
            let result = compressedData.withUnsafeMutableBytes { outputBuffer -> (Int, Int32) in
                guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return (0, Z_STREAM_ERROR)
                }
                stream.avail_out = uInt(bufferSize - totalOut)
                stream.next_out = outputBase.advanced(by: totalOut)
                
                let deflateStatus = deflate(&stream, Z_FINISH)
                let currentTotal = Int(stream.total_out)
                
                return (currentTotal, deflateStatus)
            }
            
            totalOut = result.0
            let deflateStatus = result.1
            
            if deflateStatus == Z_STREAM_END {
                finished = true
            } else if deflateStatus == Z_BUF_ERROR || totalOut >= bufferSize {
                // Output buffer full, need more space
                bufferSize *= 2
                var newData = Data(count: bufferSize)
                newData[0..<compressedData.count] = compressedData[0..<compressedData.count]
                compressedData = newData
            } else if deflateStatus != Z_OK {
                throw CompressionError.compressionFailed
            }
        }
        
        guard totalOut > 0 else {
            throw CompressionError.compressionFailed
        }
        
        compressedData.count = totalOut
        
        // Build gzip format: header + compressed data + footer
        var gzipData = Data()
        
        // Gzip header (10 bytes)
        gzipData.append(0x1f)  // Magic number 1
        gzipData.append(0x8b)  // Magic number 2
        gzipData.append(0x08)  // Compression method (deflate)
        gzipData.append(0x00)  // Flags (none)
        gzipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Modification time (0 = not set)
        gzipData.append(0x00)  // Extra flags
        gzipData.append(0xff)  // OS (255 = unknown)
        
        // Compressed data (raw deflate stream)
        gzipData.append(compressedData)
        
        // Gzip footer (8 bytes): CRC32 and original size
        let crc32Value: uLong = data.withUnsafeBytes { bytes in
            let ptr = bytes.bindMemory(to: UInt8.self).baseAddress
            return crc32(0, ptr, uInt(data.count))
        }
        var crc32Bytes = withUnsafeBytes(of: crc32Value.littleEndian) { Data($0) }
        gzipData.append(crc32Bytes)
        
        var sizeBytes = withUnsafeBytes(of: UInt32(data.count).littleEndian) { Data($0) }
        gzipData.append(sizeBytes)
        
        return gzipData
    }
    
    /// Decompress gzip-compressed data (compatible with Java GZIPOutputStream)
    /// - Parameter data: Gzip-compressed data
    /// - Returns: Decompressed data
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return data
        }
        
        // Check for gzip magic numbers
        guard data.count >= 10,
              data[0] == 0x1f && data[1] == 0x8b else {
            throw CompressionError.decompressionFailed
        }
        
        // Skip gzip header (10 bytes minimum, may be longer if extra fields present)
        var headerSize = 10
        let flags = data[3]
        
        // Check for extra fields
        if (flags & 0x04) != 0 {
            // Extra field present - read length (2 bytes)
            guard data.count >= headerSize + 2 else {
                throw CompressionError.decompressionFailed
            }
            let extraLen = Int(data[headerSize]) | (Int(data[headerSize + 1]) << 8)
            headerSize += 2 + extraLen
        }
        
        // Check for filename
        if (flags & 0x08) != 0 {
            // Filename present - skip until null terminator
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }
        
        // Check for comment
        if (flags & 0x10) != 0 {
            // Comment present - skip until null terminator
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }
        
        // Extract compressed data (skip header and footer)
        guard data.count >= headerSize + 8 else {
            throw CompressionError.decompressionFailed
        }
        let compressedData = data.subdata(in: headerSize..<(data.count - 8))
        
        // Use inflate with gzip window bits to decompress raw deflate
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        
        var inputData = compressedData
        stream.avail_in = uInt(inputData.count)
        stream.next_in = inputData.withUnsafeMutableBytes { UnsafeMutablePointer(mutating: $0.bindMemory(to: Bytef.self).baseAddress!) }
        
        // Initialize inflate with gzip format (MAX_WBITS + 16)
        let windowBits = MAX_WBITS + 16  // +16 for gzip format
        let status = inflateInit2_(
            &stream,
            Int32(windowBits),
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        
        guard status == Z_OK else {
            throw CompressionError.decompressionFailed
        }
        defer { inflateEnd(&stream) }
        
        // Allocate output buffer
        var bufferSize = compressedData.count * 4
        var buffer = Data(count: bufferSize)
        var totalOut: Int = 0
        var attempts = 0
        
        // Decompress with increasing buffer sizes if needed
        while attempts < 3 {
            var outputSize = bufferSize
            buffer.withUnsafeMutableBytes { outputBuffer in
                guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return
                }
                stream.avail_out = uInt(outputSize)
                stream.next_out = outputBase
                
                let inflateStatus = inflate(&stream, Z_FINISH)
                
                if inflateStatus == Z_STREAM_END {
                    totalOut = Int(stream.total_out)
                } else if inflateStatus == Z_BUF_ERROR {
                    // Buffer too small, will retry
                } else if inflateStatus != Z_OK {
                    // Error
                }
            }
            
            if totalOut > 0 {
                break
            } else {
                // Buffer too small, try larger
                bufferSize *= 2
                buffer = Data(count: bufferSize)
                // Reset stream for retry
                stream.avail_in = uInt(inputData.count)
                stream.next_in = inputData.withUnsafeMutableBytes { UnsafeMutablePointer(mutating: $0.bindMemory(to: Bytef.self).baseAddress!) }
                inflateReset(&stream)
                attempts += 1
            }
        }
        
        guard totalOut > 0 else {
            throw CompressionError.decompressionFailed
        }
        
        buffer.count = totalOut
        return buffer
    }
}

