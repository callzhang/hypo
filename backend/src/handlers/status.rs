use actix_web::{web, HttpResponse};
use serde_json::json;
use crate::AppState;
use crate::services::metrics::get_metrics;

pub async fn status_handler(data: web::Data<AppState>) -> HttpResponse {
    let uptime_seconds = data.start_time.elapsed().as_secs();
    
    // Get active connection count and device list from SessionManager
    let active_connections = data.sessions.get_active_count().await;
    let connected_devices = data.sessions.get_connected_devices().await;
    
    // Get metrics (call once and reuse)
    let metrics = get_metrics().await;
    let messages_processed = metrics.as_ref()
        .map(|m| m.messages_processed.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    
    let redis_operations = metrics.as_ref()
        .map(|m| m.redis_operations.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    
    let error_count = metrics.as_ref()
        .map(|m| m.error_count.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    
    // Get average request duration
    let avg_request_duration_ms = if let Some(ref metrics) = metrics {
        let durations = metrics.request_durations.read().await;
        if !durations.is_empty() {
            let avg = durations.iter().sum::<f64>() / durations.len() as f64;
            Some(avg * 1000.0)
        } else {
            None
        }
    } else {
        None
    };
    
    HttpResponse::Ok().json(json!({
        "status": "ok",
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "uptime_seconds": uptime_seconds,
        "connections": {
            "active": active_connections,
            "devices": connected_devices,
            "description": "Number of active WebSocket connections (devices) and list of connected device IDs"
        },
        "messages": {
            "processed": messages_processed,
            "description": "Total number of messages processed since server start"
        },
        "redis": {
            "operations": redis_operations,
            "description": "Total number of Redis operations since server start"
        },
        "errors": {
            "count": error_count,
            "description": "Total number of errors since server start"
        },
        "performance": {
            "avg_request_duration_ms": avg_request_duration_ms,
            "description": "Average request duration in milliseconds (last 1000 requests)"
        },
        "message_queue": {
            "pending_messages": 0,
            "queued_per_device": {},
            "description": "Message queue statistics (planned feature: queue messages when device offline, retry with exponential backoff up to 2048s timeout)"
        }
    }))
}

