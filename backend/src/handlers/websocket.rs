use actix_web::{web, Error, HttpRequest, HttpResponse};
use actix_ws::Message;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::Deserialize;
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
    let key_store = data.device_keys.clone();

    actix_web::rt::spawn(async move {
        while let Some(Ok(msg)) = msg_stream.recv().await {
            match msg {
                Message::Text(text) => {
                    if let Err(err) =
                        handle_text_message(&reader_device_id, &text, &reader_sessions, &key_store)
                            .await
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
    key_store: &crate::services::device_key_store::DeviceKeyStore,
) -> Result<(), SessionError> {
    let parsed: ClipboardMessage = match serde_json::from_str(message) {
        Ok(value) => value,
        Err(err) => {
            warn!("Received invalid message from {}: {}", sender_id, err);
            return Ok(());
        }
    };

    let payload: &Value = &parsed.payload;

    if parsed.msg_type == crate::models::message::MessageType::Control {
        handle_control_message(sender_id, payload, key_store).await;
        return Ok(());
    }

    if let Err(err) = validate_encryption_block(payload) {
        warn!("Discarding message from {}: {}", sender_id, err);
        return Ok(());
    }

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

#[derive(Debug, Deserialize)]
struct RegisterKeyPayload {
    action: String,
    #[serde(default)]
    _device_id: Option<String>,
    #[serde(default)]
    symmetric_key: Option<String>,
}

async fn handle_control_message(
    sender_id: &str,
    payload: &Value,
    key_store: &crate::services::device_key_store::DeviceKeyStore,
) {
    let Ok(registration) = serde_json::from_value::<RegisterKeyPayload>(payload.clone()) else {
        warn!("Invalid control payload from {}", sender_id);
        return;
    };

    match registration.action.as_str() {
        "register_key" => {
            let Some(encoded_key) = registration.symmetric_key else {
                warn!("register_key missing symmetric_key field for {}", sender_id);
                return;
            };

            match BASE64.decode(encoded_key.as_bytes()) {
                Ok(key) if key.len() == 32 => {
                    key_store.store(sender_id.to_string(), key).await;
                    info!("Registered symmetric key for device {}", sender_id);
                }
                Ok(_) => {
                    warn!(
                        "Key registration rejected for {}: invalid key length",
                        sender_id
                    );
                }
                Err(err) => {
                    warn!("Failed to decode symmetric key for {}: {}", sender_id, err);
                }
            }
        }
        "deregister_key" => {
            key_store.remove(sender_id).await;
            info!("Deregistered symmetric key for device {}", sender_id);
        }
        other => {
            warn!("Unhandled control action '{}' from {}", other, sender_id);
        }
    }
}

fn validate_encryption_block(payload: &Value) -> Result<(), &'static str> {
    let Some(encryption) = payload.get("encryption") else {
        return Err("missing encryption block");
    };

    let nonce = encryption
        .get("nonce")
        .and_then(Value::as_str)
        .ok_or("missing nonce")?;
    let tag = encryption
        .get("tag")
        .and_then(Value::as_str)
        .ok_or("missing tag")?;

    BASE64
        .decode(nonce.as_bytes())
        .map_err(|_| "invalid nonce encoding")
        .and_then(|decoded| {
            if decoded.len() == 12 {
                Ok(())
            } else {
                Err("nonce must be 12 bytes")
            }
        })?;

    BASE64
        .decode(tag.as_bytes())
        .map_err(|_| "invalid tag encoding")
        .and_then(|decoded| {
            if decoded.len() == 16 {
                Ok(())
            } else {
                Err("tag must be 16 bytes")
            }
        })?;

    let data = payload
        .get("data")
        .and_then(Value::as_str)
        .ok_or("missing data field")?;

    BASE64
        .decode(data.as_bytes())
        .map_err(|_| "invalid data encoding")
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::aead;
    use serde_json::json;
    use tokio::time::{timeout, Duration};
    use uuid::Uuid;

    #[actix_rt::test]
    async fn register_key_control_message_stores_key() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let payload = json!({
            "action": "register_key",
            "symmetric_key": BASE64.encode([0u8; 32])
        });

        handle_control_message("device-1", &payload, &store).await;

        assert!(store.is_registered("device-1").await);
    }

    #[actix_rt::test]
    async fn register_key_control_message_rejects_bad_base64() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let payload = json!({
            "action": "register_key",
            "symmetric_key": "not-base64!!"
        });

        handle_control_message("device-err", &payload, &store).await;

        assert!(!store.is_registered("device-err").await);
    }

    #[actix_rt::test]
    async fn register_key_control_message_rejects_wrong_length() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let payload = json!({
            "action": "register_key",
            "symmetric_key": BASE64.encode([0u8; 8])
        });

        handle_control_message("device-short", &payload, &store).await;

        assert!(!store.is_registered("device-short").await);
    }

    #[actix_rt::test]
    async fn deregister_key_control_message_removes_key() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        store.store("device-1".into(), vec![1; 32]).await;
        assert!(store.is_registered("device-1").await);

        let payload = json!({
            "action": "deregister_key"
        });

        handle_control_message("device-1", &payload, &store).await;

        assert!(!store.is_registered("device-1").await);
    }

    fn base_message(payload: serde_json::Value) -> String {
        json!({
            "id": Uuid::new_v4(),
            "timestamp": "2025-01-01T00:00:00Z",
            "version": "1.0",
            "type": "clipboard",
            "payload": payload
        })
        .to_string()
    }

    fn encryption_block() -> serde_json::Value {
        json!({
            "nonce": BASE64.encode([5u8; 12]),
            "tag": BASE64.encode([6u8; 16])
        })
    }

    fn encryption_block_from(result: &aead::EncryptionResult) -> serde_json::Value {
        json!({
            "nonce": BASE64.encode(result.nonce),
            "tag": BASE64.encode(result.tag)
        })
    }

    #[actix_rt::test]
    async fn handle_text_message_broadcasts_without_target() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut sender_rx = sessions.register("sender".into()).await;
        let mut receiver_rx = sessions.register("receiver".into()).await;

        let payload = json!({
            "data": BASE64.encode(b"clipboard"),
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get broadcast")
            .expect("channel open");
        assert_eq!(forwarded, message);

        assert!(
            sender_rx.try_recv().is_err(),
            "sender should not receive broadcast"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_routes_direct_targets() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut sender_rx = sessions.register("sender".into()).await;
        let mut receiver_rx = sessions.register("receiver".into()).await;
        let mut other_rx = sessions.register("other".into()).await;

        let payload = json!({
            "data": BASE64.encode(b"clipboard"),
            "target": "receiver",
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get direct message")
            .expect("channel open");
        assert_eq!(forwarded, message);

        assert!(
            sender_rx.try_recv().is_err(),
            "sender should not receive direct message"
        );
        assert!(
            other_rx.try_recv().is_err(),
            "non-target should not receive direct message"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_rejects_invalid_json() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut receiver_rx = sessions.register("receiver".into()).await;

        handle_text_message("sender", "not-json", &sessions, &key_store)
            .await
            .expect("invalid payload should be ignored");

        assert!(
            timeout(Duration::from_millis(50), receiver_rx.recv())
                .await
                .is_err(),
            "no message should be forwarded"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_requires_encryption_block() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut receiver_rx = sessions.register("receiver".into()).await;

        let payload = json!({
            "data": BASE64.encode(b"clipboard")
        });

        let message = base_message(payload);

        handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect("message handled");

        assert!(
            timeout(Duration::from_millis(50), receiver_rx.recv())
                .await
                .is_err(),
            "messages missing encryption should be dropped"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_drops_on_invalid_data_encoding() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut receiver_rx = sessions.register("receiver".into()).await;

        let payload = json!({
            "data": "not-base64!!",
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect("invalid payload should be ignored");

        assert!(
            timeout(Duration::from_millis(50), receiver_rx.recv())
                .await
                .is_err(),
            "invalid data should not be forwarded"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_returns_error_when_target_missing() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let payload = json!({
            "data": BASE64.encode(b"clipboard"),
            "target": "ghost",
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        let err = handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect_err("missing target should return error");
        assert!(matches!(err, SessionError::DeviceNotConnected));
    }

    #[actix_rt::test]
    async fn encrypted_payload_relays_to_other_devices() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut sender_rx = sessions.register("sender".into()).await;
        let mut receiver_rx = sessions.register("receiver".into()).await;

        let key = [9u8; 32];
        let aad = br#"{"type":"clipboard"}"#;
        let encrypted = aead::encrypt(&key, b"hello", aad).expect("encrypt payload");

        let payload = json!({
            "data": BASE64.encode(&encrypted.ciphertext),
            "encryption": encryption_block_from(&encrypted)
        });

        let message = base_message(payload);

        handle_text_message("sender", &message, &sessions, &key_store)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get broadcast")
            .expect("channel open");
        assert_eq!(forwarded, message);

        assert!(sender_rx.try_recv().is_err());
    }

    #[test]
    fn validate_encryption_block_checks_lengths() {
        let payload = json!({
            "data": BASE64.encode(b"cipher"),
            "encryption": {
                "nonce": BASE64.encode([1u8; 12]),
                "tag": BASE64.encode([2u8; 16])
            }
        });

        assert!(validate_encryption_block(&payload).is_ok());

        let bad_payload = json!({
            "data": "not-base64",
            "encryption": {
                "nonce": BASE64.encode([1u8; 12]),
                "tag": BASE64.encode([2u8; 16])
            }
        });

        assert!(validate_encryption_block(&bad_payload).is_err());
    }
}
