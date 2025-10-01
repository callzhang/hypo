use actix_web::{web, Error, HttpRequest, HttpResponse};
use actix_ws::Message;
use serde_json::Value;
use tracing::{error, info, warn};

use crate::models::message::ClipboardMessage;
use crate::services::session_manager::SessionError;
use crate::AppState;

pub async fn websocket_handler(
    req: HttpRequest,
    body: web::Payload,
    data: web::Data<AppState>,
) -> Result<HttpResponse, Error> {
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
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Missing X-Device-Id or X-Device-Platform header"
        })));
    }

    let device_id = device_id.unwrap();
    let platform = platform.unwrap();

    info!(
        "WebSocket connection request from device: {} ({})",
        device_id, platform
    );

    let (response, session, mut msg_stream) = actix_ws::handle(&req, body)?;

    let mut outbound = data.sessions.register(device_id.clone()).await;

    let mut writer_session = session.clone();
    let writer_sessions = data.sessions.clone();
    let writer_device_id = device_id.clone();
    actix_web::rt::spawn(async move {
        while let Some(message) = outbound.recv().await {
            if let Err(err) = writer_session.text(message).await {
                error!("Failed to push message to {}: {:?}", writer_device_id, err);
                break;
            }
        }
        writer_sessions.unregister(&writer_device_id).await;
        info!("Session closed for device: {}", writer_device_id);
    });

    let mut reader_session = session;
    let reader_sessions = data.sessions.clone();
    let reader_device_id = device_id.clone();

    actix_web::rt::spawn(async move {
        while let Some(Ok(msg)) = msg_stream.recv().await {
            match msg {
                Message::Text(text) => {
                    if let Err(err) =
                        handle_text_message(&reader_device_id, &text, &reader_sessions).await
                    {
                        error!(
                            "Failed to handle message from {}: {:?}",
                            reader_device_id, err
                        );
                    }
                }
                Message::Ping(bytes) => {
                    let _ = reader_session.pong(&bytes).await;
                }
                Message::Close(_) => {
                    break;
                }
                _ => {}
            }
        }
        reader_sessions.unregister(&reader_device_id).await;
        info!("WebSocket closed for device: {}", reader_device_id);
    });

    Ok(response)
}

async fn handle_text_message(
    sender_id: &str,
    message: &str,
    sessions: &crate::services::session_manager::SessionManager,
) -> Result<(), SessionError> {
    let parsed: ClipboardMessage = match serde_json::from_str(message) {
        Ok(value) => value,
        Err(err) => {
            warn!("Received invalid message from {}: {}", sender_id, err);
            return Ok(());
        }
    };

    let payload: &Value = &parsed.payload;
    let target_device = payload
        .get("target")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);

    if let Some(target) = target_device {
        sessions.send(&target, message).await
    } else {
        sessions.broadcast_except(sender_id, message).await;
        Ok(())
    }
}
