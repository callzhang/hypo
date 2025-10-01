use actix_web::{web, App, HttpServer, HttpResponse, HttpRequest};
use actix_web::middleware::Logger;
use std::time::Instant;
use tracing::{info, error};

mod handlers;
mod models;
mod services;
mod middleware;
mod utils;

use handlers::websocket::websocket_handler;
use handlers::health::health_check;
use services::redis_client::RedisClient;

#[derive(Clone)]
pub struct AppState {
    pub redis: RedisClient,
    pub start_time: Instant,
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // Initialize environment
    dotenv::dotenv().ok();
    
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"))
        )
        .init();

    // Load configuration
    let host = std::env::var("SERVER_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = std::env::var("SERVER_PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse::<u16>()
        .expect("SERVER_PORT must be a valid port number");
    let redis_url = std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());

    info!("Starting Hypo Relay Server");
    info!("Connecting to Redis at {}", redis_url);

    // Initialize Redis client
    let redis_client = RedisClient::new(&redis_url)
        .await
        .expect("Failed to connect to Redis");

    let app_state = AppState {
        redis: redis_client,
        start_time: Instant::now(),
    };

    info!("Server starting on {}:{}", host, port);

    // Start HTTP server
    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(app_state.clone()))
            .wrap(Logger::default())
            .route("/ws", web::get().to(websocket_handler))
            .route("/health", web::get().to(health_check))
            .route("/metrics", web::get().to(metrics_handler))
    })
    .workers(num_cpus::get())
    .bind((host.as_str(), port))?
    .run()
    .await
}

async fn metrics_handler() -> HttpResponse {
    // TODO: Implement Prometheus metrics
    HttpResponse::Ok().body("# Metrics endpoint - coming soon\n")
}

