use actix_web::middleware::Logger;
use actix_web::dev::Service as _;
use actix_web::{web, App, HttpResponse, HttpServer};
use hypo_relay::{
    handlers::{
        health::health_check,
        pairing::{
            claim_pairing_code, create_pairing_code, poll_ack, poll_challenge, submit_ack,
            submit_challenge,
        },
        peers::connected_peers_handler,
        status::status_handler,
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

            // Opt-in, deliberately. Redis being unreachable in a deployment is
            // a fault worth failing on: sessions and pairing entries would stop
            // being shared, so two relay instances would not see each other's
            // devices and pairing would break in ways that look like a client
            // bug. Locally there is no second instance and often no Redis at
            // all, and this is the only thing that stops the relay starting.
            //
            // The message above used to promise exactly this fallback and then
            // return an error on the next line.
            if std::env::var("ALLOW_NO_REDIS").as_deref() == Ok("1") {
                error!("ALLOW_NO_REDIS=1: continuing with an in-memory store. Single process only — do not run more than one instance like this.");
                RedisClient::new_in_memory().await
            } else {
                error!("Set ALLOW_NO_REDIS=1 to run without it (single process, local development only).");
                return Err(std::io::Error::new(
                    std::io::ErrorKind::ConnectionRefused,
                    format!("Redis connection failed: {:?}", e)
                ));
            }
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
            // Times every request except the websocket upgrade. /ws is a
            // long-lived connection — one of them can last hours — and folding
            // that into an average request duration would bury every real
            // measurement under it. Nothing recorded durations before this, so
            // /status reported avg_request_duration_ms as null.
            .wrap_fn(|req, srv| {
                let is_websocket = req.path() == "/ws";
                let started = std::time::Instant::now();
                let fut = srv.call(req);
                async move {
                    let res = fut.await;
                    if !is_websocket {
                        let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
                        if let Some(m) = get_metrics().await {
                            m.record_request_duration(elapsed_ms).await;
                        }
                    }
                    res
                }
            })
            .wrap(Logger::default())
            .route("/ws", web::get().to(websocket_handler))
            .route("/health", web::get().to(health_check))
            .route("/status", web::get().to(status_handler))
            .route("/metrics", web::get().to(metrics_handler))
            .route("/peers", web::get().to(connected_peers_handler))
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
