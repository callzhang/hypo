use actix_web::{test, web, App};
use hmac::{Hmac, Mac};
use base64::Engine;
use hypo_relay::{
    handlers::websocket::websocket_handler,
    services::{device_key_store::DeviceKeyStore, redis_client::RedisClient, session_manager::SessionManager},
    AppState,
};
use std::time::Instant;

fn compute_ws_auth_token(secret: &str, device_id: &str) -> String {
    let mut mac = Hmac::<sha2::Sha256>::new_from_slice(secret.as_bytes())
        .expect("HMAC key");
    mac.update(device_id.as_bytes());
    let digest = mac.finalize().into_bytes();
    base64::engine::general_purpose::STANDARD.encode(digest)
}

async fn create_test_app_state() -> Option<AppState> {
    let redis_url = std::env::var("REDIS_URL")
        .unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    let redis = match RedisClient::new(&redis_url).await {
        Ok(client) => client,
        Err(_) => {
            println!("Skipping test: Redis not available");
            return None;
        }
    };

    Some(AppState {
        redis,
        start_time: Instant::now(),
        sessions: SessionManager::new(),
        device_keys: DeviceKeyStore::new(),
    })
}

#[actix_rt::test]
async fn websocket_rejects_missing_auth_token() {
    std::env::set_var("RELAY_WS_AUTH_TOKEN", "test-secret");
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => return,
    };

    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/ws", web::get().to(websocket_handler)),
    )
    .await;

    let req = test::TestRequest::get()
        .uri("/ws")
        .insert_header(("Upgrade", "websocket"))
        .insert_header(("Connection", "Upgrade"))
        .insert_header(("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="))
        .insert_header(("Sec-WebSocket-Version", "13"))
        .insert_header(("X-Device-Id", "550e8400-e29b-41d4-a716-446655440000"))
        .insert_header(("X-Device-Platform", "macos"))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::UNAUTHORIZED);
}

#[actix_rt::test]
async fn websocket_accepts_valid_auth_token() {
    std::env::set_var("RELAY_WS_AUTH_TOKEN", "test-secret");
    let device_id = "550e8400-e29b-41d4-a716-446655440000";
    let token = compute_ws_auth_token("test-secret", device_id);

    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => return,
    };

    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/ws", web::get().to(websocket_handler)),
    )
    .await;

    let req = test::TestRequest::get()
        .uri("/ws")
        .insert_header(("Upgrade", "websocket"))
        .insert_header(("Connection", "Upgrade"))
        .insert_header(("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="))
        .insert_header(("Sec-WebSocket-Version", "13"))
        .insert_header(("X-Device-Id", device_id))
        .insert_header(("X-Device-Platform", "macos"))
        .insert_header(("X-Auth-Token", token))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::SWITCHING_PROTOCOLS);
}
