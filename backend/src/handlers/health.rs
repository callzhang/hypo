use actix_web::{web, HttpResponse};
use serde_json::json;

use crate::AppState;

pub async fn health_check(data: web::Data<AppState>) -> HttpResponse {
    let uptime_seconds = data.start_time.elapsed().as_secs();
    
    // TODO: Check Redis connection
    // TODO: Get actual connection count
    
    HttpResponse::Ok().json(json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "uptime_seconds": uptime_seconds,
        "connections": 0,  // Placeholder
    }))
}

