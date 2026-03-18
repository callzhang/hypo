use std::collections::HashSet;

use actix_web::{web, HttpResponse};
use serde::Deserialize;

use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct PeersQuery {
    #[serde(default)]
    pub device_id: Option<String>,
}

pub async fn connected_peers_handler(
    data: web::Data<AppState>,
    query: web::Query<PeersQuery>,
) -> HttpResponse {
    let mut requested = HashSet::new();

    if let Some(ids) = &query.device_id {
        for id in ids.split(',') {
            let trimmed = id.trim();
            if !trimmed.is_empty() {
                requested.insert(trimmed.to_lowercase());
            }
        }
    }

    if requested.is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({
            "error": "device_id query parameter is required"
        }));
    }

    let mut connected_devices = data.sessions.get_connected_devices_info().await;
    connected_devices.retain(|info| requested.contains(&info.device_id));

    HttpResponse::Ok().json(serde_json::json!({
        "connected_devices": connected_devices
    }))
}
