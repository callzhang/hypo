use actix_web::{web, HttpResponse};
use serde_json::json;

use crate::AppState;

pub async fn health_check(data: web::Data<AppState>) -> HttpResponse {
    let uptime_seconds = data.start_time.elapsed().as_secs();
    let connection_count = data.sessions.get_active_count().await;
    let connected_devices = data.sessions.get_connected_devices().await;
    let session_info = data.sessions.get_session_info().await;
    
    // TODO: Check Redis connection
    
    HttpResponse::Ok().json(json!({
        "status": "ok",
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "uptime_seconds": uptime_seconds,
        "connections": connection_count,
        "connected_devices": connected_devices,
        "session_info": session_info.iter().map(|(device_id, token)| json!({
            "device_id": device_id,
            "token": token
        })).collect::<Vec<_>>(),
    }))
}

