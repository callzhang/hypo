use actix_web::{web, Error, HttpRequest, HttpResponse};
use actix_ws::Message;
use tracing::{info, warn, error};

use crate::AppState;

pub async fn websocket_handler(
    req: HttpRequest,
    body: web::Payload,
    data: web::Data<AppState>,
) -> Result<HttpResponse, Error> {
    // Extract device ID from header
    let device_id = req
        .headers()
        .get("X-Device-Id")
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());

    let platform = req
        .headers()
        .get("X-Device-Platform")
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());

    if device_id.is_none() || platform.is_none() {
        warn!("WebSocket connection rejected: missing device headers");
        return Ok(HttpResponse::BadRequest()
            .json(serde_json::json!({
                "error": "Missing X-Device-Id or X-Device-Platform header"
            })));
    }

    let device_id = device_id.unwrap();
    let platform = platform.unwrap();

    info!("WebSocket connection request from device: {} ({})", device_id, platform);

    // Upgrade to WebSocket
    let (response, mut session, mut msg_stream) = actix_ws::handle(&req, body)?;

    // TODO: Register device in Redis
    // TODO: Spawn handler task
    
    info!("WebSocket connection established for device: {}", device_id);

    // Spawn connection handler
    actix_web::rt::spawn(async move {
        while let Some(Ok(msg)) = msg_stream.recv().await {
            match msg {
                Message::Text(text) => {
                    info!("Received message from {}: {}", device_id, text);
                    // TODO: Parse and route message
                }
                Message::Ping(bytes) => {
                    let _ = session.pong(&bytes).await;
                }
                Message::Close(_) => {
                    info!("WebSocket closed for device: {}", device_id);
                    break;
                }
                _ => {}
            }
        }
    });

    Ok(response)
}

