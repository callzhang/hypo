# Hypo Backend Relay Server

Lightweight WebSocket relay server for clipboard sync when devices are not on the same LAN.

---

## Overview

The backend relay:
- Routes end-to-end encrypted clipboard messages between devices
- Never stores clipboard content (stateless)
- Uses Redis for ephemeral connection state (device UUID → WebSocket connection)
- Implements rate limiting and monitoring
- Built with Rust for performance and security

**Architecture**: Stateless relay, horizontally scalable

---

## Requirements

- **Rust**: 1.75+
- **Redis**: 7+ (or Docker)
- **Docker** (optional, for containerized deployment)

---

## Project Structure

```
backend/
├── src/
│   ├── main.rs                 # Entry point, Actix-web server
│   ├── handlers/
│   │   ├── mod.rs
│   │   ├── websocket.rs        # WebSocket handler
│   │   └── health.rs           # Health check endpoint
│   ├── models/
│   │   ├── mod.rs
│   │   ├── message.rs          # Message types
│   │   └── device.rs           # Device info
│   ├── services/
│   │   ├── mod.rs
│   │   ├── router.rs           # Message routing logic
│   │   ├── redis_client.rs     # Redis connection pool
│   │   └── rate_limiter.rs     # Token bucket rate limiter
│   ├── middleware/
│   │   ├── mod.rs
│   │   ├── auth.rs             # Device authentication
│   │   └── logging.rs          # Request logging
│   └── utils/
│       ├── mod.rs
│       └── config.rs           # Configuration management
├── tests/
│   ├── integration_test.rs
│   └── load_test.rs
├── Cargo.toml
├── Cargo.lock
├── Dockerfile
├── docker-compose.yml
└── .env.example
```

---

## Getting Started

### 1. Install Dependencies

```bash
# Install Rust (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Verify installation
rustc --version
cargo --version
```

### 2. Start Redis

**Option A: Docker**
```bash
docker run -d -p 6379:6379 --name redis redis:7-alpine
```

**Option B: Local**
```bash
brew install redis  # macOS
redis-server
```

### 3. Configure Environment

```bash
cp .env.example .env
```

Edit `.env`:
```env
RUST_LOG=info
SERVER_HOST=0.0.0.0
SERVER_PORT=8080
REDIS_URL=redis://localhost:6379
MAX_CONNECTIONS=1000
RATE_LIMIT_PER_MIN=100
MESSAGE_SIZE_LIMIT=2097152  # 2MB
```

### 4. Build and Run

```bash
# Development
cargo run

# Production (optimized)
cargo build --release
./target/release/hypo-relay
```

Server will start on `http://localhost:8080`

---

## API Endpoints

### WebSocket Connection

```
WS /ws
```

**Headers**:
- `Upgrade: websocket`
- `Connection: Upgrade`
- `X-Device-Id: <UUID>` (required)
- `X-Device-Platform: macos|android` (required)

**Example**:
```javascript
const ws = new WebSocket('ws://localhost:8080/ws', {
    headers: {
        'X-Device-Id': '550e8400-e29b-41d4-a716-446655440000',
        'X-Device-Platform': 'macos'
    }
});
```

### Health Check

```
GET /health
```

**Response**:
```json
{
    "status": "ok",
    "timestamp": "2025-10-01T12:34:56.789Z",
    "connections": 42,
    "uptime_seconds": 3600
}
```

### Metrics (Prometheus)

```
GET /metrics
```

**Example Output**:
```
# HELP hypo_connections_total Total WebSocket connections
# TYPE hypo_connections_total counter
hypo_connections_total 1234

# HELP hypo_messages_routed_total Total messages routed
# TYPE hypo_messages_routed_total counter
hypo_messages_routed_total 56789

# HELP hypo_message_latency_seconds Message routing latency
# TYPE hypo_message_latency_seconds histogram
hypo_message_latency_seconds_bucket{le="0.001"} 1000
hypo_message_latency_seconds_bucket{le="0.01"} 5000
```

---

## Core Components

### WebSocket Handler

```rust
pub struct ClipboardWebSocket {
    device_id: String,
    redis: RedisClient,
    rate_limiter: RateLimiter,
}

impl StreamHandler<Result<ws::Message, ws::ProtocolError>> for ClipboardWebSocket {
    fn handle(&mut self, msg: Result<ws::Message, ws::ProtocolError>, ctx: &mut Self::Context) {
        match msg {
            Ok(ws::Message::Text(text)) => {
                if let Ok(clip_msg) = serde_json::from_str::<ClipboardMessage>(&text) {
                    // Rate limit check
                    if !self.rate_limiter.allow() {
                        ctx.text(error_message("RATE_LIMITED"));
                        return;
                    }
                    
                    // Route message to target device
                    let target_device_id = self.get_paired_device(&clip_msg.device_id);
                    self.route_message(target_device_id, text);
                }
            }
            Ok(ws::Message::Ping(msg)) => ctx.pong(&msg),
            Ok(ws::Message::Close(_)) => ctx.stop(),
            _ => {}
        }
    }
}
```

### Message Router

```rust
pub async fn route_message(
    redis: &RedisClient,
    target_device_id: &str,
    message: &str,
) -> Result<(), RouterError> {
    // Look up target device's connection ID
    let conn_id: Option<String> = redis
        .get(format!("device:{}", target_device_id))
        .await?;
    
    match conn_id {
        Some(id) => {
            // Forward message to target connection
            send_to_connection(&id, message).await?;
            Ok(())
        }
        None => Err(RouterError::DeviceNotConnected),
    }
}
```

### Rate Limiter

```rust
pub struct RateLimiter {
    tokens: Arc<Mutex<f64>>,
    max_tokens: f64,
    refill_rate: f64, // tokens per second
    last_refill: Arc<Mutex<Instant>>,
}

impl RateLimiter {
    pub fn allow(&self) -> bool {
        let mut tokens = self.tokens.lock().unwrap();
        let mut last_refill = self.last_refill.lock().unwrap();
        
        // Refill tokens based on elapsed time
        let now = Instant::now();
        let elapsed = now.duration_since(*last_refill).as_secs_f64();
        *tokens = (*tokens + elapsed * self.refill_rate).min(self.max_tokens);
        *last_refill = now;
        
        // Check if we have tokens
        if *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}
```

---

## Redis Schema

### Device → Connection Mapping

```
Key: device:<device_uuid>
Value: <connection_id>
TTL: 3600 seconds (1 hour)
```

### Connection → Device Mapping

```
Key: conn:<connection_id>
Value: <device_uuid>
TTL: 3600 seconds
```

### Device Pairing

```
Key: pairing:<6-digit-code>
Value: <device_uuid>:<ecdh_public_key>
TTL: 300 seconds (5 minutes)
```

---

## Deployment

### Docker

```bash
# Build image
docker build -t hypo-relay .

# Run with Docker Compose
docker-compose up -d

# View logs
docker-compose logs -f relay
```

### Fly.io

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Create app
flyctl launch

# Deploy
flyctl deploy

# Scale
flyctl scale count 3
```

**fly.toml**:
```toml
app = "hypo-relay"
primary_region = "sjc"

[build]
  image = "hypo-relay:latest"

[env]
  RUST_LOG = "info"
  SERVER_PORT = "8080"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 2

[[services]]
  protocol = "tcp"
  internal_port = 8080

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]

  [[services.tcp_checks]]
    interval = "15s"
    timeout = "2s"
    grace_period = "5s"
```

---

## Monitoring

### Prometheus + Grafana

1. Add Prometheus to `docker-compose.yml`:
```yaml
prometheus:
  image: prom/prometheus:latest
  volumes:
    - ./prometheus.yml:/etc/prometheus/prometheus.yml
  ports:
    - "9090:9090"

grafana:
  image: grafana/grafana:latest
  ports:
    - "3000:3000"
  environment:
    - GF_SECURITY_ADMIN_PASSWORD=admin
```

2. Configure Prometheus (`prometheus.yml`):
```yaml
scrape_configs:
  - job_name: 'hypo-relay'
    static_configs:
      - targets: ['relay:8080']
```

3. Import Grafana dashboard (see `docs/grafana-dashboard.json`)

### Key Metrics

- **hypo_connections_total**: Total WebSocket connections
- **hypo_messages_routed_total**: Messages successfully routed
- **hypo_messages_dropped_total**: Messages dropped (device offline)
- **hypo_rate_limits_total**: Rate limit violations
- **hypo_message_latency_seconds**: P50/P95/P99 routing latency

---

## Testing

### Unit Tests

```bash
cargo test
```

### Integration Tests

```bash
cargo test --test integration_test
```

### Load Testing

```bash
# Using Apache Bench
ab -n 10000 -c 100 -H "X-Device-Id: test" ws://localhost:8080/ws

# Using custom load test
cargo test --release --test load_test -- --ignored
```

**Target**: Handle 1000 concurrent connections with <10ms P95 latency

---

## Security

### TLS Configuration

```rust
use rustls::{Certificate, PrivateKey, ServerConfig};

let config = ServerConfig::builder()
    .with_safe_defaults()
    .with_no_client_auth()
    .with_single_cert(load_certs(), load_private_key())?;

HttpServer::new(move || {
    App::new()
        .wrap(middleware::Logger::default())
        .route("/ws", web::get().to(websocket_handler))
})
.bind_rustls("0.0.0.0:8443", config)?
.run()
.await
```

### Rate Limiting

- **Per Device**: 100 messages per minute
- **Burst**: Allow 10 messages in 1 second
- **Violation**: Return error message, increment counter

### Authentication

- Validate `X-Device-Id` header format (UUID)
- Optional: HMAC signature verification for added security

---

## Performance Optimization

### Actix-web Tuning

```rust
HttpServer::new(|| {
    App::new()
        .app_data(web::Data::new(redis_pool.clone()))
        .route("/ws", web::get().to(websocket_handler))
})
.workers(num_cpus::get())  // One worker per CPU core
.max_connections(10000)    // Max concurrent connections
.keep_alive(Duration::from_secs(75))
.run()
```

### Redis Connection Pooling

```rust
use redis::aio::ConnectionManager;

let redis_client = redis::Client::open("redis://localhost")?;
let redis_pool = ConnectionManager::new(redis_client).await?;
```

---

## Troubleshooting

### High Latency

- Check Redis latency: `redis-cli --latency`
- Review Prometheus metrics for bottlenecks
- Scale horizontally (add more relay servers)

### Connection Drops

- Increase keep-alive timeout
- Check network stability
- Review rate limiter settings

### Memory Usage

- Monitor with: `docker stats`
- Redis: Set max memory policy (`maxmemory-policy allkeys-lru`)
- Rust: Profile with `valgrind` or `heaptrack`

---

## Roadmap

- [ ] Support WebSocket compression (permessage-deflate)
- [ ] Implement message queue (RabbitMQ) for offline device buffering
- [ ] Add geo-distributed relay servers (multi-region)
- [ ] Implement device-to-device direct NAT traversal (STUN/TURN)
- [ ] Add admin dashboard for monitoring

---

**Status**: In Development  
**Last Updated**: October 1, 2025

