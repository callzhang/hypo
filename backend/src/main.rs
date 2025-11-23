use actix_web::middleware::Logger;
use actix_web::{web, App, HttpResponse, HttpServer};
use hypo_relay::{
    handlers::{
        health::health_check,
        pairing::{
            claim_pairing_code, create_pairing_code, poll_ack, poll_challenge, submit_ack,
            submit_challenge,
        },
        websocket::websocket_handler,
    },
    services::{
        device_key_store::DeviceKeyStore, 
        redis_client::RedisClient,
        session_manager::SessionManager,
        metrics::{initialize_metrics, get_metrics},
    },
    AppState,
};
use std::time::Instant;
use tracing::{info, error};

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    dotenv::dotenv().ok();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let host = std::env::var("SERVER_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = std::env::var("SERVER_PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse::<u16>()
        .expect("SERVER_PORT must be a valid port number");
    let redis_url =
        std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());

    info!("Starting Hypo Relay Server");
    info!("Connecting to Redis at {}", redis_url);

    // Initialize metrics
    if let Err(e) = initialize_metrics().await {
        error!("Failed to initialize metrics: {}", e);
    }

    let redis_client = match RedisClient::new(&redis_url).await {
        Ok(client) => {
            info!("Successfully connected to Redis at {}", redis_url);
            client
        }
        Err(e) => {
            error!("Failed to connect to Redis at {}: {:?}", redis_url, e);
            error!("Server will continue without Redis (sessions will be in-memory only)");
            // For now, we'll still require Redis, but log the error clearly
            return Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionRefused,
                format!("Redis connection failed: {:?}", e)
            ));
        }
    };

    let app_state = AppState {
        redis: redis_client,
        start_time: Instant::now(),
        sessions: SessionManager::new(),
        device_keys: DeviceKeyStore::new(),
    };

    info!("Server starting on {}:{}", host, port);

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(app_state.clone()))
            .wrap(Logger::default())
            .route("/ws", web::get().to(websocket_handler))
            .route("/health", web::get().to(health_check))
            .route("/metrics", web::get().to(metrics_handler))
            .service(
                web::scope("/pairing")
                    .route("/code", web::post().to(create_pairing_code))
                    .route("/claim", web::post().to(claim_pairing_code))
                    .route("/code/{code}/challenge", web::post().to(submit_challenge))
                    .route("/code/{code}/challenge", web::get().to(poll_challenge))
                    .route("/code/{code}/ack", web::post().to(submit_ack))
                    .route("/code/{code}/ack", web::get().to(poll_ack)),
            )
    })
    .workers(4) // Optimize for concurrent connections
    .keep_alive(std::time::Duration::from_secs(30))
    .client_request_timeout(std::time::Duration::from_secs(5)) // 5 second timeout
    .bind((host.as_str(), port))?
    .run()
    .await
}

async fn metrics_handler() -> HttpResponse {
    match get_metrics().await {
        Some(metrics) => {
            let stats = metrics.get_stats().await;
            let mut output = String::new();
            for (key, value) in stats {
                output.push_str(&format!("# HELP {} {}\n", key, key));
                output.push_str(&format!("# TYPE {} gauge\n", key));
                output.push_str(&format!("{} {}\n", key, value));
            }
            HttpResponse::Ok()
                .content_type("text/plain; version=0.0.4; charset=utf-8")
                .body(output)
        }
        None => HttpResponse::ServiceUnavailable()
            .body("Metrics not initialized")
    }
}
