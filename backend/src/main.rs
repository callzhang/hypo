use actix_web::middleware::Logger;
use actix_web::{web, App, HttpResponse, HttpServer};
use std::time::Instant;
use tracing::info;

mod handlers;
mod middleware;
mod models;
mod services;
mod utils;

use handlers::health::health_check;
use handlers::websocket::websocket_handler;
use services::redis_client::RedisClient;
use services::session_manager::SessionManager;

#[derive(Clone)]
pub struct AppState {
    pub redis: RedisClient,
    pub start_time: Instant,
    pub sessions: SessionManager,
}

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

    let redis_client = RedisClient::new(&redis_url)
        .await
        .expect("Failed to connect to Redis");

    let app_state = AppState {
        redis: redis_client,
        start_time: Instant::now(),
        sessions: SessionManager::new(),
    };

    info!("Server starting on {}:{}", host, port);

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(app_state.clone()))
            .wrap(Logger::default())
            .route("/ws", web::get().to(websocket_handler))
            .route("/health", web::get().to(health_check))
            .route("/metrics", web::get().to(metrics_handler))
    })
    .bind((host.as_str(), port))?
    .run()
    .await
}

async fn metrics_handler() -> HttpResponse {
    HttpResponse::Ok().body("# Metrics endpoint - coming soon\n")
}
