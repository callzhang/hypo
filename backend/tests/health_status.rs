use actix_web::{test, web, App};
use hypo_relay::{
    handlers::{health::health_check, status::status_handler},
    services::{device_key_store::DeviceKeyStore, redis_client::RedisClient, session_manager::SessionManager},
    AppState,
};
use std::time::Instant;

async fn create_test_app_state() -> Option<AppState> {
    let redis_url = std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    let redis = match RedisClient::new(&redis_url).await {
        Ok(client) => client,
        Err(_) => {
            // Skip tests if Redis is not available (e.g., in CI without Redis service)
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
async fn test_health_check_returns_ok() {
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => {
            println!("Skipping test: Redis not available");
            return;
        }
    };
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/health", web::get().to(health_check)),
    )
    .await;

    let req = test::TestRequest::get().uri("/health").to_request();
    let resp = test::call_service(&app, req).await;

    assert!(resp.status().is_success());
    
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["status"], "ok");
    assert!(body["timestamp"].is_string());
    assert!(body["uptime_seconds"].is_number());
    assert!(body["connections"].is_number());
}

#[actix_rt::test]
async fn test_status_handler_returns_comprehensive_info() {
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => {
            println!("Skipping test: Redis not available");
            return;
        }
    };
    
    // Register some devices to test connection counts
    let _alice = app_state.sessions.register("alice".to_string()).await;
    let _bob = app_state.sessions.register("bob".to_string()).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state))
            .route("/status", web::get().to(status_handler)),
    )
    .await;

    let req = test::TestRequest::get().uri("/status").to_request();
    let resp = test::call_service(&app, req).await;

    assert!(resp.status().is_success());
    
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["status"], "ok");
    assert!(body["timestamp"].is_string());
    assert!(body["uptime_seconds"].is_number());
    
    // Check connections structure
    assert!(body["connections"].is_object());
    assert!(body["connections"]["active"].is_number());
    assert!(body["connections"]["devices"].is_array());
    assert!(body["connections"]["description"].is_string());
    
    // Check messages structure
    assert!(body["messages"].is_object());
    assert!(body["messages"]["processed"].is_number());
    assert!(body["messages"]["description"].is_string());
    
    // Check redis structure
    assert!(body["redis"].is_object());
    assert!(body["redis"]["operations"].is_number());
    assert!(body["redis"]["description"].is_string());
    
    // Check errors structure
    assert!(body["errors"].is_object());
    assert!(body["errors"]["count"].is_number());
    assert!(body["errors"]["description"].is_string());
    
    // Check performance structure
    assert!(body["performance"].is_object());
    assert!(body["performance"]["description"].is_string());
}

#[actix_rt::test]
async fn test_status_handler_reflects_active_connections() {
    let app_state = match create_test_app_state().await {
        Some(state) => state,
        None => {
            println!("Skipping test: Redis not available");
            return;
        }
    };
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(app_state.clone()))
            .route("/status", web::get().to(status_handler)),
    )
    .await;

    // Check initial state (no connections)
    let req = test::TestRequest::get().uri("/status").to_request();
    let resp = test::call_service(&app, req).await;
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["connections"]["active"], 0);
    assert_eq!(body["connections"]["devices"].as_array().unwrap().len(), 0);

    // Register devices
    let _device1 = app_state.sessions.register("device-1".to_string()).await;
    let _device2 = app_state.sessions.register("device-2".to_string()).await;

    // Check updated state
    let req = test::TestRequest::get().uri("/status").to_request();
    let resp = test::call_service(&app, req).await;
    let body: serde_json::Value = test::read_body_json(resp).await;
    
    assert_eq!(body["connections"]["active"], 2);
    let devices = body["connections"]["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 2);
    assert!(devices.contains(&serde_json::json!("device-1")));
    assert!(devices.contains(&serde_json::json!("device-2")));
}

