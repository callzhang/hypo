use actix_web::{test, web, App};
use hypo_relay::{
    handlers::pairing::{
        claim_pairing_code, create_pairing_code, poll_ack, poll_challenge, submit_ack,
        submit_challenge,
    },
    services::{device_key_store::DeviceKeyStore, redis_client::RedisClient, session_manager::SessionManager},
    AppState,
};
use std::time::Instant;

async fn create_test_app_state() -> Option<AppState> {
    let redis_url = std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    // Note: These are integration tests that require Redis
    // Run with: docker compose up redis
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
async fn test_create_pairing_code_success() {
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
            .route("/pairing/code", web::post().to(create_pairing_code)),
    )
    .await;

    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({
            "initiator_device_id": "device-1",
            "initiator_device_name": "Test Device",
            "initiator_public_key": "test-public-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());

    let body: serde_json::Value = test::read_body_json(resp).await;
    assert!(body["code"].is_string());
    assert!(body["expires_at"].is_string());
}

#[actix_rt::test]
async fn test_create_pairing_code_invalid_request() {
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
            .route("/pairing/code", web::post().to(create_pairing_code)),
    )
    .await;

    // Missing required fields
    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({}))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_client_error());
}

#[actix_rt::test]
async fn test_claim_pairing_code_success() {
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
            .route("/pairing/code", web::post().to(create_pairing_code))
            .route("/pairing/code/{code}/claim", web::post().to(claim_pairing_code)),
    )
    .await;

    // First create a pairing code
    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({
            "initiator_device_id": "device-1",
            "initiator_device_name": "Initiator",
            "initiator_public_key": "initiator-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());
    let body: serde_json::Value = test::read_body_json(resp).await;
    let code = body["code"].as_str().unwrap();

    // Now claim it
    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/claim", code))
        .set_json(&serde_json::json!({
            "code": code,
            "responder_device_id": "device-2",
            "responder_device_name": "Responder",
            "responder_public_key": "responder-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());

    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["initiator_device_id"], "device-1");
    assert_eq!(body["initiator_device_name"], "Initiator");
}

#[actix_rt::test]
async fn test_claim_pairing_code_not_found() {
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
            .route("/pairing/code/{code}/claim", web::post().to(claim_pairing_code)),
    )
    .await;

    let req = test::TestRequest::post()
        .uri("/pairing/code/INVALID-CODE/claim")
        .set_json(&serde_json::json!({
            "code": "INVALID-CODE",
            "responder_device_id": "device-2",
            "responder_device_name": "Responder",
            "responder_public_key": "responder-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::NOT_FOUND);
}

#[actix_rt::test]
async fn test_claim_pairing_code_already_claimed() {
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
            .route("/pairing/code", web::post().to(create_pairing_code))
            .route("/pairing/code/{code}/claim", web::post().to(claim_pairing_code)),
    )
    .await;

    // Create and claim once
    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({
            "initiator_device_id": "device-1",
            "initiator_device_name": "Initiator",
            "initiator_public_key": "initiator-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    let body: serde_json::Value = test::read_body_json(resp).await;
    let code = body["code"].as_str().unwrap();

    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/claim", code))
        .set_json(&serde_json::json!({
            "code": code,
            "responder_device_id": "device-2",
            "responder_device_name": "Responder",
            "responder_public_key": "responder-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());

    // Try to claim again
    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/claim", code))
        .set_json(&serde_json::json!({
            "code": code,
            "responder_device_id": "device-3",
            "responder_device_name": "Another Responder",
            "responder_public_key": "another-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::CONFLICT);
}

#[actix_rt::test]
async fn test_challenge_submit_and_poll() {
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
            .route("/pairing/code", web::post().to(create_pairing_code))
            .route("/pairing/code/{code}/claim", web::post().to(claim_pairing_code))
            .route("/pairing/code/{code}/challenge", web::post().to(submit_challenge))
            .route("/pairing/code/{code}/challenge", web::get().to(poll_challenge)),
    )
    .await;

    // Create and claim pairing code
    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({
            "initiator_device_id": "device-1",
            "initiator_device_name": "Initiator",
            "initiator_public_key": "initiator-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    let body: serde_json::Value = test::read_body_json(resp).await;
    let code = body["code"].as_str().unwrap();

    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/claim", code))
        .set_json(&serde_json::json!({
            "code": code,
            "responder_device_id": "device-2",
            "responder_device_name": "Responder",
            "responder_public_key": "responder-key",
        }))
        .to_request();

    test::call_service(&app, req).await;

    // Submit challenge
    let challenge_req = serde_json::json!({
        "responder_device_id": "device-2",
        "challenge": "test-challenge-data"
    });

    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/challenge", code))
        .set_json(&challenge_req)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::ACCEPTED);

    // Poll challenge
    let req = test::TestRequest::get()
        .uri(&format!("/pairing/code/{}/challenge?initiator_device_id=device-1", code))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());

    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["challenge"], "test-challenge-data");
}

#[actix_rt::test]
async fn test_ack_submit_and_poll() {
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
            .route("/pairing/code", web::post().to(create_pairing_code))
            .route("/pairing/code/{code}/claim", web::post().to(claim_pairing_code))
            .route("/pairing/code/{code}/ack", web::post().to(submit_ack))
            .route("/pairing/code/{code}/ack", web::get().to(poll_ack)),
    )
    .await;

    // Create and claim pairing code
    let req = test::TestRequest::post()
        .uri("/pairing/code")
        .set_json(&serde_json::json!({
            "initiator_device_id": "device-1",
            "initiator_device_name": "Initiator",
            "initiator_public_key": "initiator-key",
        }))
        .to_request();

    let resp = test::call_service(&app, req).await;
    let body: serde_json::Value = test::read_body_json(resp).await;
    let code = body["code"].as_str().unwrap();

    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/claim", code))
        .set_json(&serde_json::json!({
            "code": code,
            "responder_device_id": "device-2",
            "responder_device_name": "Responder",
            "responder_public_key": "responder-key",
        }))
        .to_request();

    test::call_service(&app, req).await;

    // Submit ack
    let ack_req = serde_json::json!({
        "initiator_device_id": "device-1",
        "ack": "test-ack-data"
    });

    let req = test::TestRequest::post()
        .uri(&format!("/pairing/code/{}/ack", code))
        .set_json(&ack_req)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), actix_web::http::StatusCode::ACCEPTED);

    // Poll ack
    let req = test::TestRequest::get()
        .uri(&format!("/pairing/code/{}/ack?responder_device_id=device-2", code))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_success());

    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["ack"], "test-ack-data");
}

