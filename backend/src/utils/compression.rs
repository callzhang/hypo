use anyhow::Result;
use flate2::{Compression, read::GzDecoder, write::GzEncoder};
use std::io::{Read, Write};
use tracing::debug;

const COMPRESSION_THRESHOLD: usize = 1024; // Compress payloads larger than 1KB
const MIN_COMPRESSION_RATIO: f64 = 0.9; // Only use compression if it saves at least 10%

#[derive(Debug, Clone)]
pub struct CompressionConfig {
    pub threshold_bytes: usize,
    pub min_ratio: f64,
    pub level: Compression,
}

impl Default for CompressionConfig {
    fn default() -> Self {
        Self {
            threshold_bytes: COMPRESSION_THRESHOLD,
            min_ratio: MIN_COMPRESSION_RATIO,
            level: Compression::default(),
        }
    }
}

pub fn compress_if_beneficial(data: &[u8], config: &CompressionConfig) -> Result<(Vec<u8>, bool)> {
    // Skip compression for small payloads
    if data.len() < config.threshold_bytes {
        debug!("Payload too small for compression: {} bytes", data.len());
        return Ok((data.to_vec(), false));
    }

    // Attempt compression
    let mut encoder = GzEncoder::new(Vec::new(), config.level);
    encoder.write_all(data)?;
    let compressed = encoder.finish()?;

    // Check if compression is beneficial
    let compression_ratio = compressed.len() as f64 / data.len() as f64;
    if compression_ratio < config.min_ratio {
        debug!(
            "Compression beneficial: {} bytes -> {} bytes ({:.1}%)",
            data.len(),
            compressed.len(),
            compression_ratio * 100.0
        );
        Ok((compressed, true))
    } else {
        debug!(
            "Compression not beneficial: {} bytes -> {} bytes ({:.1}%)",
            data.len(),
            compressed.len(),
            compression_ratio * 100.0
        );
        Ok((data.to_vec(), false))
    }
}

pub fn decompress(data: &[u8]) -> Result<Vec<u8>> {
    let mut decoder = GzDecoder::new(data);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)?;
    debug!("Decompressed {} bytes -> {} bytes", data.len(), decompressed.len());
    Ok(decompressed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compression_small_payload() {
        let data = b"small";
        let config = CompressionConfig::default();
        let (result, compressed) = compress_if_beneficial(data, &config).unwrap();
        assert!(!compressed);
        assert_eq!(result, data);
    }

    #[test]
    fn test_compression_large_payload() {
        // Create a large, compressible payload
        let data = "a".repeat(2000);
        let config = CompressionConfig::default();
        let (compressed_data, was_compressed) = compress_if_beneficial(data.as_bytes(), &config).unwrap();
        
        if was_compressed {
            assert!(compressed_data.len() < data.len());
            
            // Test decompression
            let decompressed = decompress(&compressed_data).unwrap();
            assert_eq!(decompressed, data.as_bytes());
        }
    }

    #[test]
    fn test_compression_random_payload() {
        // Random data typically doesn't compress well
        let data: Vec<u8> = (0..2000).map(|i| (i % 256) as u8).collect();
        let config = CompressionConfig::default();
        let (result, compressed) = compress_if_beneficial(&data, &config).unwrap();
        
        // Depending on the data, compression may or may not be beneficial
        if compressed {
            let decompressed = decompress(&result).unwrap();
            assert_eq!(decompressed, data);
        } else {
            assert_eq!(result, data);
        }
    }
}