use std::sync::Arc;
use tokio::sync::RwLock;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Default)]
pub struct Metrics {
    pub websocket_connections: Arc<AtomicU64>,
    pub messages_processed: Arc<AtomicU64>,
    pub redis_operations: Arc<AtomicU64>,
    pub error_count: Arc<AtomicU64>,
    pub request_durations: Arc<RwLock<Vec<f64>>>,
}

impl Metrics {
    pub fn new() -> Self {
        Self::default()
    }
    
    pub fn increment_websocket_connections(&self) {
        self.websocket_connections.fetch_add(1, Ordering::Relaxed);
    }
    
    pub fn decrement_websocket_connections(&self) {
        self.websocket_connections.fetch_sub(1, Ordering::Relaxed);
    }
    
    pub fn increment_messages(&self) {
        self.messages_processed.fetch_add(1, Ordering::Relaxed);
    }
    
    pub fn increment_redis_ops(&self) {
        self.redis_operations.fetch_add(1, Ordering::Relaxed);
    }
    
    pub fn increment_errors(&self) {
        self.error_count.fetch_add(1, Ordering::Relaxed);
    }
    
    pub async fn record_request_duration(&self, duration: f64) {
        let mut durations = self.request_durations.write().await;
        durations.push(duration);
        // Keep only last 1000 measurements
        if durations.len() > 1000 {
            durations.drain(0..500);
        }
    }
    
    pub async fn get_stats(&self) -> HashMap<String, String> {
        let mut stats = HashMap::new();
        stats.insert("websocket_connections".to_string(), 
                    self.websocket_connections.load(Ordering::Relaxed).to_string());
        stats.insert("messages_processed".to_string(),
                    self.messages_processed.load(Ordering::Relaxed).to_string());
        stats.insert("redis_operations".to_string(),
                    self.redis_operations.load(Ordering::Relaxed).to_string());
        stats.insert("error_count".to_string(),
                    self.error_count.load(Ordering::Relaxed).to_string());
        
        let durations = self.request_durations.read().await;
        if !durations.is_empty() {
            let avg = durations.iter().sum::<f64>() / durations.len() as f64;
            stats.insert("avg_request_duration_ms".to_string(), (avg * 1000.0).to_string());
        }
        
        stats
    }
}

// Global metrics instance
static METRICS: once_cell::sync::Lazy<Arc<RwLock<Option<Metrics>>>> = 
    once_cell::sync::Lazy::new(|| Arc::new(RwLock::new(None)));

pub async fn initialize_metrics() -> Result<(), Box<dyn std::error::Error>> {
    let metrics = Metrics::new();
    *METRICS.write().await = Some(metrics);
    Ok(())
}

pub async fn get_metrics() -> Option<Metrics> {
    METRICS.read().await.clone()
}