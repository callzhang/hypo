use actix_web::{test, web, App};
use hypo_relay::{
    handlers::peers::connected_peers_handler,
    services::{device_key_store::DeviceKeyStore, redis_client::RedisClient, session_manager::SessionManager},
    AppState,
};
use std::time::Instant;

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
async fn peers_requires_device_id_filter() {
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => return,
    };

    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/peers", web::get().to(connected_peers_handler)),
    )
    .await;

    let req = test::TestRequest::get().uri("/peers").to_request();
    let resp = test::call_service(&app, req).await;

    assert_eq!(resp.status(), actix_web::http::StatusCode::BAD_REQUEST);
}

#[actix_rt::test]
async fn peers_filters_to_requested_devices() {
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => return,
    };

    let _alice = app_state.sessions.register("alice".to_string()).await;
    let _bob = app_state.sessions.register("bob".to_string()).await;

    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/peers", web::get().to(connected_peers_handler)),
    )
    .await;

    let req = test::TestRequest::get()
        .uri("/peers?device_id=bob,charlie")
        .to_request();
    let resp = test::call_service(&app, req).await;

    assert!(resp.status().is_success());
    let body: serde_json::Value = test::read_body_json(resp).await;
    let connected = body["connected_devices"].as_array().expect("connected_devices");
    assert_eq!(connected.len(), 1);
    assert_eq!(connected[0]["device_id"], "bob");
    assert!(connected[0]["last_seen"].is_string());
}
