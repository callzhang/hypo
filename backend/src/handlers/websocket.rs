use actix_web::{web, Error, HttpRequest, HttpResponse};
use actix_ws::Message;
use base64::engine::general_purpose::{STANDARD as BASE64, STANDARD_NO_PAD as BASE64_NO_PAD};
use base64::Engine;
use chrono::Utc;
use serde::Deserialize;
use serde_json::Value;
use tracing::{error, info, warn};

use crate::models::message::ClipboardMessage;
use crate::services::session_manager::SessionError;
use crate::AppState;


pub async fn websocket_handler(
    req: HttpRequest,
    _body: web::Payload,
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

    // Normalize device ID to lowercase for consistent matching across platforms
    let device_id = device_id.unwrap().to_lowercase();
    let platform = platform.unwrap();

    info!(
        "WebSocket connection request from device: {} ({})",
        device_id, platform
    );

    info!("About to call actix_ws::handle for {} ({})", device_id, platform);
    let (response, session, mut msg_stream) = match actix_ws::handle(&req, _body) {
        Ok(result) => {
            info!("actix_ws::handle succeeded for {} ({})", device_id, platform);
            result
        }
        Err(e) => {
            error!(
                "actix_ws::handle failed for {} ({}): {:?}",
                device_id, platform, e
            );
            error!(
                "  This may indicate a buffer overflow during WebSocket handshake/upgrade"
            );
            return Err(e);
        }
    };

    // CRITICAL: Configure max_frame_size to 1GB to support large file transfers
    // This removes the 64KB default limit in actix-ws 0.2.x
    // With actix-ws 0.3.0, we can set this to 1GB (1_073_741_824 bytes)
    const MAX_FRAME_SIZE: usize = 1_073_741_824; // 1GB
    msg_stream = msg_stream.max_frame_size(MAX_FRAME_SIZE);
    info!(
        "Configured max_frame_size to {} bytes (1GB) for device {} ({})",
        MAX_FRAME_SIZE, device_id, platform
    );

    info!("Registering WebSocket session for device: {} ({})", device_id, platform);
    let registration = data.sessions.register(device_id.clone()).await;
    let mut outbound = registration.receiver;
    let session_token = registration.token;
    let connection_start_time = std::time::Instant::now();
    info!(
        "Session registered successfully for device: {} (token={}) at {:?}",
        device_id, session_token, connection_start_time
    );

    let mut writer_session = session.clone();
    let writer_sessions = data.sessions.clone();
    let writer_device_id = device_id.clone();
    let writer_token = session_token;
    let writer_start_time = std::time::Instant::now();
    actix_web::rt::spawn(async move {
        // Simple stateless relay: just forward messages, fail fast if connection is closed
        let mut message_count = 0u64;
        while let Some(message) = outbound.recv().await {
            message_count += 1;
            let last_message_time = std::time::Instant::now();
            
            // message is already in binary frame format (4-byte length + JSON)
            if let Err(err) = writer_session.binary(message).await {
                // Connection closed or error - log detailed information
                let connection_duration = writer_start_time.elapsed();
                let time_since_last_message = last_message_time.elapsed();
                warn!(
                    "Writer task failed for device {} (token {}): {:?}",
                    writer_device_id, writer_token, err
                );
                warn!(
                    "  Connection duration: {:.2}s, Messages sent: {}, Time since last message: {:.2}s",
                    connection_duration.as_secs_f64(),
                    message_count,
                    time_since_last_message.as_secs_f64()
                );
                break;
            }
        }
        
        let connection_duration = writer_start_time.elapsed();
        let removed = writer_sessions
            .unregister_with_token(&writer_device_id, writer_token)
            .await;
        if removed {
            info!(
                "Writer task finished for device {} (token {}): duration={:.2}s, messages={}",
                writer_device_id, writer_token, connection_duration.as_secs_f64(), message_count
            );
        } else {
            info!(
                "Stale writer task finished for device {} (token {}). Newer session remains active. Duration={:.2}s, messages={}",
                writer_device_id, writer_token, connection_duration.as_secs_f64(), message_count
            );
        }
    });

    let mut reader_session = session;
    let reader_sessions = data.sessions.clone();
    let reader_device_id = device_id.clone();
    let reader_token = session_token;
    let key_store = data.device_keys.clone();
    let reader_start_time = std::time::Instant::now();

    actix_web::rt::spawn(async move {
        let mut message_count = 0u64;
        let mut error_count = 0u64;
        let mut last_message_time = reader_start_time;
        let mut close_reason = String::from("stream_ended_normally");
        
        loop {
            match msg_stream.recv().await {
                Some(Ok(msg)) => {
                    message_count += 1;
                    last_message_time = std::time::Instant::now();
                    
                    match msg {
                        Message::Text(text) => {
                            // Legacy text format - decode and convert to binary frame
                            if let Err(err) =
                                handle_text_message(&reader_device_id, &text, &reader_sessions, &key_store, &mut reader_session)
                                    .await
                            {
                                error_count += 1;
                                // DeviceNotConnected is expected when target device is offline - log as warn
                                // Other errors (InvalidMessage, SendError) are actual problems - log as error
                                match &err {
                                    SessionError::DeviceNotConnected => {
                                        warn!(
                                            "Target device not connected for message from {}: {:?}",
                                            reader_device_id, err
                                        );
                                    }
                                    _ => {
                                        error!(
                                            "Failed to handle message from {}: {:?}",
                                            reader_device_id, err
                                        );
                                    }
                                }
                            }
                        }
                        Message::Binary(bytes) => {
                            // Reject empty binary frames to prevent probing/ambiguity
                            if bytes.is_empty() {
                                warn!("Empty binary frame received from {}", reader_device_id);
                                close_reason = "empty_binary_frame".to_string();
                                let _ = reader_session.close(None).await;
                                break;
                            }
                            // Binary frame format (4-byte length + JSON) - forward as-is
                            if let Err(err) =
                                handle_binary_message(&reader_device_id, &bytes, &reader_sessions, &key_store, &mut reader_session)
                                    .await
                            {
                                error_count += 1;
                                // DeviceNotConnected is expected when target device is offline - log as warn
                                // Other errors (InvalidMessage, SendError) are actual problems - log as error
                                match &err {
                                    SessionError::DeviceNotConnected => {
                                        warn!(
                                            "Target device not connected for message from {}: {:?}",
                                            reader_device_id, err
                                        );
                                    }
                                    _ => {
                                        error!(
                                            "Failed to handle binary message from {}: {:?}",
                                            reader_device_id, err
                                        );
                                    }
                                }
                            }
                        }
                        Message::Ping(bytes) => {
                            if let Err(e) = reader_session.pong(&bytes).await {
                                warn!("Failed to send pong to {}: {:?}", reader_device_id, e);
                            }
                        }
                        Message::Close(close_frame) => {
                            if let Some(frame) = close_frame {
                                close_reason = format!(
                                    "close_frame_code_{:?}_description_{}",
                                    frame.code,
                                    frame.description.as_deref().unwrap_or("none")
                                );
                            } else {
                                close_reason = String::from("close_frame_no_details");
                            }
                            info!(
                                "Received close frame from {} (token {}): {}",
                                reader_device_id, reader_token, close_reason
                            );
                            break;
                        }
                        _ => {}
                    }
                }
                Some(Err(e)) => {
                    error_count += 1;
                    close_reason = format!("stream_error_{:?}", e);
                    
                    let connection_duration = reader_start_time.elapsed();
                    let time_since_last_message = last_message_time.elapsed();
                    
                    error!(
                        "Reader stream error for device {} (token {}): {:?}",
                        reader_device_id, reader_token, e
                    );
                    error!(
                        "  Connection duration: {:.2}s, Messages received: {}, Errors: {}, Time since last message: {:.2}s",
                        connection_duration.as_secs_f64(),
                        message_count,
                        error_count,
                        time_since_last_message.as_secs_f64()
                    );
                    break;
                }
                None => {
                    break;
                }
            }
        }
        
        let connection_duration = reader_start_time.elapsed();
        let time_since_last_message = last_message_time.elapsed();
        let removed = reader_sessions
            .unregister_with_token(&reader_device_id, reader_token)
            .await;
        if removed {
            info!(
                "Reader task finished for device {} (token {}): reason={}, duration={:.2}s, messages={}, errors={}, time_since_last_message={:.2}s",
                reader_device_id, reader_token, close_reason, connection_duration.as_secs_f64(), message_count, error_count, time_since_last_message.as_secs_f64()
            );
        } else {
            info!(
                "Skipped unregister for device {} (token {}) because a newer session is active. reason={}, duration={:.2}s, messages={}, errors={}",
                reader_device_id, reader_token, close_reason, connection_duration.as_secs_f64(), message_count, error_count
            );
        }
    });

    Ok(response)
}

/// Decode binary frame (4-byte big-endian length + JSON payload)
fn decode_binary_frame(data: &[u8]) -> Result<String, &'static str> {
    if data.len() < 4 {
        return Err("frame too short");
    }
    
    // Read 4-byte big-endian length
    let length = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
    
    if data.len() < 4 + length {
        return Err("frame truncated");
    }
    
    if data.len() != 4 + length {
        return Err("frame has trailing bytes");
    }
    
    // Extract JSON payload
    let json_bytes = &data[4..4 + length];
    let json_str = std::str::from_utf8(json_bytes)
        .map_err(|_| "invalid UTF-8 in JSON payload")?;
    
    Ok(json_str.to_string())
}

/// Encode JSON string to binary frame (4-byte big-endian length + JSON payload)
/// Decode base64 string with fallback to NO_PAD (Android uses Base64.withoutPadding())
/// Returns decoded bytes or error message
fn decode_base64_with_fallback(encoded: &str, field_name: &str) -> Result<Vec<u8>, &'static str> {
    BASE64
        .decode(encoded.as_bytes())
        .or_else(|_| BASE64_NO_PAD.decode(encoded.as_bytes()))
        .map_err(|e| {
            error!(
                "Failed to decode {}: {} (string: '{}', length: {}, first 20 chars: '{}')",
                field_name,
                e,
                encoded,
                encoded.len(),
                if encoded.len() > 20 { &encoded[..20] } else { encoded }
            );
            match field_name {
                "nonce" => "invalid nonce encoding",
                "tag" => "invalid tag encoding",
                "data" | "ciphertext" => "invalid data encoding",
                _ => "invalid base64 encoding",
            }
        })
}

fn encode_binary_frame(json_str: &str) -> Vec<u8> {
    let json_bytes = json_str.as_bytes();
    let length = json_bytes.len() as u32;
    
    let mut frame = Vec::with_capacity(4 + json_bytes.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(json_bytes);
    frame
}

async fn handle_binary_message(
    sender_id: &str,
    frame: &[u8],
    sessions: &crate::services::session_manager::SessionManager,
    key_store: &crate::services::device_key_store::DeviceKeyStore,
    sender_session: &mut actix_ws::Session,
) -> Result<(), SessionError> {
    // Decode binary frame to get JSON string
    let json_str = decode_binary_frame(frame)
        .map_err(|e| {
            error!(
                "Failed to decode binary frame from {}: {} (frame length: {} bytes, first 20 bytes: {:?})",
                sender_id, e, frame.len(),
                if frame.len() >= 20 { &frame[..20] } else { frame }
            );
            SessionError::InvalidMessage
        })?;
    
    // Parse JSON to ClipboardMessage
    let parsed: ClipboardMessage = serde_json::from_str(&json_str)
        .map_err(|err| {
            error!(
                "Received invalid message from {}: {} (JSON length: {} bytes, first 500 chars: {})",
                sender_id, err, json_str.len(),
                json_str.chars().take(500).collect::<String>()
            );
            // Log the full JSON for debugging Android message format issues
            if json_str.len() < 2000 {
                error!("Full JSON message that failed to parse: {}", json_str);
            }
            SessionError::InvalidMessage
        })?;

    let payload: &Value = &parsed.payload;

    if parsed.msg_type == crate::models::message::MessageType::Control {
        handle_control_message(sender_id, &parsed.id, payload, key_store, sessions, sender_session).await;
        return Ok(());
    }

    // Update last_seen for this device session
    sessions.touch(sender_id).await;

    if let Err(err) = validate_encryption_block(payload) {
        warn!("Discarding message from {}: {} (payload keys: {:?})", 
            sender_id, err, 
            payload.as_object().map(|o| o.keys().collect::<Vec<_>>()).unwrap_or_default()
        );
        // Log the actual payload for debugging Android message format issues
        if let Ok(payload_str) = serde_json::to_string(payload) {
            let preview = if payload_str.len() > 500 {
                format!("{}...", &payload_str[..500])
            } else {
                payload_str
            };
            warn!("Discarded message payload preview: {}", preview);
        }
        return Ok(());
    }

    let target_device = payload
        .get("target")
        .and_then(Value::as_str)
        .map(|s| s.to_lowercase()); // Normalize target device ID to lowercase for consistent matching

    // Forward the binary frame as-is (already in correct format)
    if let Some(target) = target_device {
        info!("Routing message from {} to target device: {}", sender_id, target);
        match sessions.send_binary(&target, frame.to_vec()).await {
            Ok(()) => {
                info!("Successfully routed message to {}", target);
                Ok(())
            }
            Err(SessionError::DeviceNotConnected) => {
                let registered_devices = sessions.get_connected_devices().await;
                warn!(
                    "Target device {} not connected, message not delivered. Connected devices: {:?}",
                    target, registered_devices
                );
                
                // Send error response back to sender
                let error_message = serde_json::json!({
                    "id": parsed.id,
                    "timestamp": chrono::Utc::now().to_rfc3339(),
                    "version": "1.0",
                    "type": "error",
                    "payload": {
                        "code": "device_not_connected",
                        "message": format!("Target device {} is not connected to the relay server. Device may be offline or disconnected.", target),
                        "original_message_id": parsed.id,
                        "target_device_id": target,
                        "connected_devices": registered_devices
                    }
                });
                
                let error_frame = encode_binary_frame(&error_message.to_string());
                // Send error response - handle gracefully if session is closed (e.g., in tests)
                // In tests, the session might not be fully functional, so we handle errors gracefully
                let error_frame_size = error_frame.len();
                match sender_session.binary(error_frame).await {
                    Ok(_) => {
                        info!(
                            "Sent error response to {} for failed delivery to {} (frame_size={} bytes)",
                            sender_id, target, error_frame_size
                        );
                    }
                    Err(e) => {
                        // Log but don't fail - session might be closed (e.g., in tests or connection dropped)
                        warn!(
                            "Failed to send error response to {} for target {}: {:?} (frame_size={} bytes, session may be closed)",
                            sender_id, target, e, error_frame_size
                        );
                    }
                }
                
                Err(SessionError::DeviceNotConnected)
            }
            Err(e) => {
                error!("Failed to route message to {}: {:?}", target, e);
                Err(e)
            }
        }
    } else {
        info!("No target specified, broadcasting from {} to all other devices", sender_id);
        sessions.broadcast_except_binary(sender_id, frame.to_vec()).await;
        Ok(())
    }
}

async fn handle_text_message(
    sender_id: &str,
    message: &str,
    sessions: &crate::services::session_manager::SessionManager,
    key_store: &crate::services::device_key_store::DeviceKeyStore,
    sender_session: &mut actix_ws::Session,
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
        handle_control_message(sender_id, &parsed.id, payload, key_store, sessions, sender_session).await;
        return Ok(());
    }

    // Update last_seen for this device session
    sessions.touch(sender_id).await;

    if let Err(err) = validate_encryption_block(payload) {
        warn!("Discarding message from {}: {} (payload keys: {:?})", 
            sender_id, err, 
            payload.as_object().map(|o| o.keys().collect::<Vec<_>>()).unwrap_or_default()
        );
        // Log the actual payload for debugging Android message format issues
        if let Ok(payload_str) = serde_json::to_string(payload) {
            let preview = if payload_str.len() > 500 {
                format!("{}...", &payload_str[..500])
            } else {
                payload_str
            };
            warn!("Discarded message payload preview: {}", preview);
        }
        return Ok(());
    }

    let target_device = payload
        .get("target")
        .and_then(Value::as_str)
        .map(|s| s.to_lowercase()); // Normalize target device ID to lowercase for consistent matching

    // Convert text message to binary frame format for forwarding
    let binary_frame = encode_binary_frame(message);
    
    if let Some(target) = target_device {
        match sessions.send_binary(&target, binary_frame).await {
            Ok(()) => Ok(()),
            Err(SessionError::DeviceNotConnected) => {
                let registered_devices = sessions.get_connected_devices().await;
                warn!(
                    "Target device {} not connected, message not delivered. Connected devices: {:?}",
                    target, registered_devices
                );
                
                // Send error response back to sender
                let error_message = serde_json::json!({
                    "id": parsed.id,
                    "timestamp": Utc::now().to_rfc3339(),
                    "version": "1.0",
                    "type": "error",
                    "payload": {
                        "code": "device_not_connected",
                        "message": format!("Target device {} is not connected to the relay server. Device may be offline or disconnected.", target),
                        "original_message_id": parsed.id,
                        "target_device_id": target,
                        "connected_devices": registered_devices
                    }
                });
                
                let error_frame = encode_binary_frame(&error_message.to_string());
                // Send error response - handle gracefully if session is closed (e.g., in tests)
                // In tests, the session might not be fully functional, so we handle errors gracefully
                let error_frame_size = error_frame.len();
                match sender_session.binary(error_frame).await {
                    Ok(_) => {
                        info!(
                            "Sent error response to {} for failed delivery to {} (frame_size={} bytes)",
                            sender_id, target, error_frame_size
                        );
                    }
                    Err(e) => {
                        // Log but don't fail - session might be closed (e.g., in tests or connection dropped)
                        warn!(
                            "Failed to send error response to {} for target {}: {:?} (frame_size={} bytes, session may be closed)",
                            sender_id, target, e, error_frame_size
                        );
                    }
                }
                
                Err(SessionError::DeviceNotConnected)
            }
            Err(e) => Err(e)
        }
    } else {
        sessions.broadcast_except_binary(sender_id, binary_frame).await;
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
struct ControlMessagePayload {
    action: String,
    #[serde(default)]
    _device_id: Option<String>,
    #[serde(default)]
    symmetric_key: Option<String>,
    #[serde(default)]
    device_ids: Option<Vec<String>>,
}

async fn handle_control_message(
    sender_id: &str,
    original_message_id: &uuid::Uuid,
    payload: &Value,
    key_store: &crate::services::device_key_store::DeviceKeyStore,
    sessions: &crate::services::session_manager::SessionManager,
    sender_session: &mut actix_ws::Session,
) {
    // Update last_seen for this device session
    sessions.touch(sender_id).await;

    let Ok(control) = serde_json::from_value::<ControlMessagePayload>(payload.clone()) else {
        warn!("Invalid control payload from {}", sender_id);
        return;
    };

    match control.action.as_str() {
        "register_key" => {
            let Some(encoded_key) = control.symmetric_key else {
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
        "query_connected_peers" => {
            let mut connected_devices = sessions.get_connected_devices_info().await;
            
            // Privacy filter: if client provided a list of device IDs, only return the ones that are in that list
            if let Some(requested_ids) = control.device_ids {
                let requested_set: std::collections::HashSet<String> = requested_ids.into_iter().collect();
                connected_devices.retain(|info| requested_set.contains(&info.device_id));
                let requested_preview: Vec<String> = requested_set.iter().take(5).cloned().collect();
                let requested_suffix = if requested_set.len() > 5 {
                    format!(", …(+{})", requested_set.len().saturating_sub(5))
                } else {
                    String::new()
                };
                let connected_preview: Vec<String> = connected_devices.iter().map(|info| info.device_id.clone()).take(5).collect();
                let connected_suffix = if connected_devices.len() > 5 {
                    format!(", …(+{})", connected_devices.len().saturating_sub(5))
                } else {
                    String::new()
                };
                info!(
                    "Applied privacy filter to connected peers list for {}: returned {}/{} devices (requested=[{}{}], connected=[{}{}])",
                    sender_id,
                    connected_devices.len(),
                    requested_set.len(),
                    requested_preview.join(","),
                    requested_suffix,
                    connected_preview.join(","),
                    connected_suffix
                );
            } else {
                warn!("Client {} queried connected peers without a filter. For privacy, clients should provide device_ids.", sender_id);
            }
            let response = serde_json::json!({
                "id": uuid::Uuid::new_v4(),
                "timestamp": chrono::Utc::now().to_rfc3339(),
                "version": "1.0",
                "type": "control",
                "payload": {
                    "action": "query_connected_peers",
                    "connected_devices": connected_devices,
                    "original_message_id": original_message_id
                }
            });
            
            let response_frame = encode_binary_frame(&response.to_string());
            if let Err(e) = sender_session.binary(response_frame).await {
                warn!("Failed to send connected peers response to {}: {:?}", sender_id, e);
            } else {
                info!("Sent connected peers list to {} ({} devices)", sender_id, connected_devices.len());
            }
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

    // Handle plaintext messages: empty nonce/tag means plaintext
    if nonce.is_empty() && tag.is_empty() {
        // Plaintext message - validate data field exists and is base64 decodable
        let data = payload
            .get("ciphertext")
            .or_else(|| payload.get("data"))
            .and_then(Value::as_str)
            .ok_or("missing data/ciphertext field")?;
        
        // Android uses Base64.withoutPadding(), so we need to handle unpadded base64
        decode_base64_with_fallback(data, "data").map(|_| ())?;
        
        return Ok(());
    }

    // Encrypted message - validate nonce and tag
    // Android uses Base64.withoutPadding(), so we need to handle unpadded base64
    let nonce_decoded = decode_base64_with_fallback(nonce, "nonce")?;
    if nonce_decoded.len() != 12 {
        error!("Nonce decoded length is {} bytes, expected 12 bytes (nonce string: '{}')", nonce_decoded.len(), nonce);
        return Err("nonce must be 12 bytes");
    }

    let tag_decoded = decode_base64_with_fallback(tag, "tag")?;
    if tag_decoded.len() != 16 {
        error!("Tag decoded length is {} bytes, expected 16 bytes (tag string: '{}')", tag_decoded.len(), tag);
        return Err("tag must be 16 bytes");
    }

    // Validate ciphertext/data field for encrypted messages
    let data = payload
        .get("ciphertext")
        .or_else(|| payload.get("data"))
        .and_then(Value::as_str)
        .ok_or("missing data/ciphertext field")?;

    // Android uses Base64.withoutPadding(), so we need to handle unpadded base64
    decode_base64_with_fallback(data, "ciphertext").map(|_| ())?;
    
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::aead;
    use serde_json::json;
    use tokio::time::{timeout, Duration};
    use uuid::Uuid;
    
    // Test helper to create a test session for testing
    // Creates a real WebSocket session using actix_ws::handle with a test request
    // Note: This creates a minimal session that may not be fully functional for sending,
    // but it's sufficient for testing the message handling logic. Error sending will fail
    // gracefully in tests, which is handled in the error response code.
    async fn create_test_session() -> actix_ws::Session {
        use actix_web::http::Method;
        
        // For tests, create two requests (one for HttpRequest, one for web::Payload)
        // since to_http_request() and to_request() both take ownership
        let test_req_http = actix_web::test::TestRequest::default()
            .method(Method::GET)
            .insert_header(("Upgrade", "websocket"))
            .insert_header(("Connection", "Upgrade"))
            .insert_header(("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="))
            .insert_header(("Sec-WebSocket-Version", "13"))
            .set_payload(actix_web::web::Bytes::new());
        
        let test_req_web = actix_web::test::TestRequest::default()
            .method(Method::GET)
            .insert_header(("Upgrade", "websocket"))
            .insert_header(("Connection", "Upgrade"))
            .insert_header(("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="))
            .insert_header(("Sec-WebSocket-Version", "13"))
            .set_payload(actix_web::web::Bytes::new());
        
        // Get HttpRequest for actix_ws::handle
        let http_req = test_req_http.to_http_request();
        
        // Get web::Request to extract web::Payload
        let mut web_req = test_req_web.to_request();
        // take_payload() on web::Request returns dev::Payload, but we need web::Payload
        // Since web::Payload is just a newtype wrapper, we can safely transmute in tests
        let dev_payload = web_req.take_payload();
        // Unsafe transmute: web::Payload(dev::Payload) - safe because it's just a wrapper
        let body = unsafe {
            std::mem::transmute::<actix_web::dev::Payload, actix_web::web::Payload>(dev_payload)
        };
        
        // Create the WebSocket session using the web::Payload
        // The session creation should succeed, and error sending will fail gracefully
        // in tests, which is handled in the error response code
        let (_, session, _) = actix_ws::handle(&http_req, body).unwrap();
        session
    }

    #[actix_rt::test]
    async fn register_key_control_message_stores_key() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let sessions = crate::services::session_manager::SessionManager::new();
        let mut sender_session = create_test_session().await;
        let payload = json!({
            "action": "register_key",
            "symmetric_key": BASE64.encode([0u8; 32])
        });

        handle_control_message("device-1", &uuid::Uuid::new_v4(), &payload, &store, &sessions, &mut sender_session).await;

        assert!(store.is_registered("device-1").await);
    }

    #[actix_rt::test]
    async fn register_key_control_message_rejects_bad_base64() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let sessions = crate::services::session_manager::SessionManager::new();
        let mut sender_session = create_test_session().await;
        let payload = json!({
            "action": "register_key",
            "symmetric_key": "not-base64!!"
        });

        handle_control_message("device-err", &uuid::Uuid::new_v4(), &payload, &store, &sessions, &mut sender_session).await;

        assert!(!store.is_registered("device-err").await);
    }

    #[actix_rt::test]
    async fn register_key_control_message_rejects_wrong_length() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let sessions = crate::services::session_manager::SessionManager::new();
        let mut sender_session = create_test_session().await;
        let payload = json!({
            "action": "register_key",
            "symmetric_key": BASE64.encode([0u8; 8])
        });

        handle_control_message("device-short", &uuid::Uuid::new_v4(), &payload, &store, &sessions, &mut sender_session).await;

        assert!(!store.is_registered("device-short").await);
    }

    #[actix_rt::test]
    async fn deregister_key_control_message_removes_key() {
        let store = crate::services::device_key_store::DeviceKeyStore::new();
        let sessions = crate::services::session_manager::SessionManager::new();
        let mut sender_session = create_test_session().await;
        store.store("device-1".into(), vec![1; 32]).await;
        assert!(store.is_registered("device-1").await);

        let payload = json!({
            "action": "deregister_key"
        });

        handle_control_message("device-1", &uuid::Uuid::new_v4(), &payload, &store, &sessions, &mut sender_session).await;

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

        let mut sender_rx = sessions.register("sender".into()).await.receiver;
        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;

        let payload = json!({
            "data": BASE64.encode(b"clipboard"),
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        // Create a test session for testing (error responses will be handled gracefully)
        let mut test_session = create_test_session().await;
        handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get broadcast")
            .expect("channel open");
        let forwarded_str = std::str::from_utf8(&forwarded[4..]).expect("valid UTF-8");
        assert_eq!(forwarded_str, message);

        assert!(
            sender_rx.try_recv().is_err(),
            "sender should not receive broadcast"
        );
    }

    #[actix_rt::test]
    async fn handle_text_message_routes_direct_targets() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut sender_rx = sessions.register("sender".into()).await.receiver;
        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;
        let mut other_rx = sessions.register("other".into()).await.receiver;

        let payload = json!({
            "data": BASE64.encode(b"clipboard"),
            "target": "receiver",
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        // Create a test session for testing (error responses will be handled gracefully)
        let mut test_session = create_test_session().await;
        handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get direct message")
            .expect("channel open");
        let forwarded_str = std::str::from_utf8(&forwarded[4..]).expect("valid UTF-8");
        assert_eq!(forwarded_str, message);

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

        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;

        let mut test_session = create_test_session().await;
        handle_text_message("sender", "not-json", &sessions, &key_store, &mut test_session)
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

        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;

        let payload = json!({
            "data": BASE64.encode(b"clipboard")
        });

        let message = base_message(payload);

        // Create a test session for testing (error responses will be handled gracefully)
        let mut test_session = create_test_session().await;
        handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
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

        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;

        let payload = json!({
            "data": "not-base64!!",
            "encryption": encryption_block()
        });

        let message = base_message(payload);

        let mut test_session = create_test_session().await;
        handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
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

        let mut test_session = create_test_session().await;
        let err = handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
            .await
            .expect_err("missing target should return error");
        assert!(matches!(err, SessionError::DeviceNotConnected));
    }

    #[actix_rt::test]
    async fn encrypted_payload_relays_to_other_devices() {
        let sessions = crate::services::session_manager::SessionManager::new();
        let key_store = crate::services::device_key_store::DeviceKeyStore::new();

        let mut sender_rx = sessions.register("sender".into()).await.receiver;
        let mut receiver_rx = sessions.register("receiver".into()).await.receiver;

        let key = [9u8; 32];
        let aad = br#"{"type":"clipboard"}"#;
        let encrypted = aead::encrypt(&key, b"hello", aad).expect("encrypt payload");

        let payload = json!({
            "data": BASE64.encode(&encrypted.ciphertext),
            "encryption": encryption_block_from(&encrypted)
        });

        let message = base_message(payload);

        // Create a test session for testing (error responses will be handled gracefully)
        let mut test_session = create_test_session().await;
        handle_text_message("sender", &message, &sessions, &key_store, &mut test_session)
            .await
            .expect("message handled");

        let forwarded = timeout(Duration::from_millis(50), receiver_rx.recv())
            .await
            .expect("receiver should get broadcast")
            .expect("channel open");
        let forwarded_str = std::str::from_utf8(&forwarded[4..]).expect("valid UTF-8");
        assert_eq!(forwarded_str, message);

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
