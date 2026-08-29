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
        
        // Set all input at once
        var inputData = data
        stream.avail_in = uInt(inputData.count)
        stream.next_in = inputData.withUnsafeMutableBytes { UnsafeMutablePointer(mutating: $0.bindMemory(to: Bytef.self).baseAddress!) }
        
        // Allocate output buffer (start with reasonable size, will grow if needed)
        var bufferSize = max(1024, data.count + (data.count / 10) + 16)
        var compressedData = Data(count: bufferSize)
        var totalOut: Int = 0
        
        // Compress: call deflate until stream is finished
        // Use Z_FINISH from the start since we have all input data
        var finished = false
        while !finished {
            let result = compressedData.withUnsafeMutableBytes { outputBuffer -> (Int, Int32) in
                guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return (0, Z_STREAM_ERROR)
                }
                stream.avail_out = uInt(bufferSize - totalOut)
                stream.next_out = outputBase.advanced(by: totalOut)
                
                // Use Z_FINISH since we have all input data
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
        
        // When using MAX_WBITS + 16, deflate produces complete gzip format (header + deflate + footer)
        // So we can use the output directly without adding our own header/footer
        return compressedData
    }
    
    /// Decompress gzip-compressed data (compatible with Java GZIPInputStream)
    /// - Parameter data: Gzip-compressed data (complete gzip format from deflate with MAX_WBITS + 16)
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
        
        // Use inflate with gzip window bits to decompress complete gzip format
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        
        var inputData = data
        stream.avail_in = uInt(inputData.count)
        stream.next_in = inputData.withUnsafeMutableBytes { UnsafeMutablePointer(mutating: $0.bindMemory(to: Bytef.self).baseAddress!) }
        
        // Initialize inflate with gzip format (MAX_WBITS + 16)
        // This handles the complete gzip format (header + deflate + footer)
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
        var bufferSize = data.count * 4
        var buffer = Data(count: bufferSize)
        var totalOut: Int = 0
        
        // Decompress: call inflate until stream is finished
        var finished = false
        while !finished {
            let result = buffer.withUnsafeMutableBytes { outputBuffer -> (Int, Int32) in
                guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return (0, Z_STREAM_ERROR)
                }
                stream.avail_out = uInt(bufferSize - totalOut)
                stream.next_out = outputBase.advanced(by: totalOut)
                
                let inflateStatus = inflate(&stream, Z_FINISH)
                let currentTotal = Int(stream.total_out)
                
                return (currentTotal, inflateStatus)
            }
            
            totalOut = result.0
            let inflateStatus = result.1
            
            if inflateStatus == Z_STREAM_END {
                finished = true
            } else if inflateStatus == Z_BUF_ERROR {
                // Output buffer full, need more space
                bufferSize *= 2
                var newData = Data(count: bufferSize)
                newData[0..<buffer.count] = buffer[0..<buffer.count]
                buffer = newData
            } else if inflateStatus == Z_OK {
                // Continue - may need more output space if both exhausted
                if stream.avail_in == 0 && stream.avail_out == 0 {
                    // Need more output space to finish
                    bufferSize *= 2
                    var newData = Data(count: bufferSize)
                    newData[0..<buffer.count] = buffer[0..<buffer.count]
                    buffer = newData
                }
            } else {
                throw CompressionError.decompressionFailed
            }
        }
        
        guard totalOut > 0 else {
            throw CompressionError.decompressionFailed
        }
        
        buffer.count = totalOut
        return buffer
    }
}

