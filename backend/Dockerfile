# Build stage
FROM rust:1.83-alpine AS builder

RUN apk add --no-cache musl-dev openssl-dev

WORKDIR /app

# Copy manifests
COPY Cargo.toml ./
COPY Cargo.lock* ./

# Create dummy main.rs to cache dependencies
RUN mkdir src && \
    echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src

# Copy source code
COPY src ./src

# Build actual application
RUN touch src/main.rs && \
    cargo build --release

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache ca-certificates libgcc redis

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/target/release/hypo-relay .

# Create startup script
RUN echo '#!/bin/sh' > /app/start.sh && \
    echo 'set -e' >> /app/start.sh && \
    echo 'echo "Starting Redis..."' >> /app/start.sh && \
    echo 'redis-server --bind 127.0.0.1 --port 6379 --dir /data --daemonize yes' >> /app/start.sh && \
    echo 'sleep 2' >> /app/start.sh && \
    echo 'echo "Starting Hypo Relay Server on 0.0.0.0:8080..."' >> /app/start.sh && \
    echo 'exec ./hypo-relay' >> /app/start.sh && \
    chmod +x /app/start.sh

# Create non-root user
RUN addgroup -g 1000 hypo && \
    adduser -D -u 1000 -G hypo hypo && \
    mkdir -p /data && \
    chown -R hypo:hypo /app /data

USER hypo

EXPOSE 8080

CMD ["/app/start.sh"]

