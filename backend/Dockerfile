# Build stage
FROM rust:1.75-alpine AS builder

RUN apk add --no-cache musl-dev openssl-dev

WORKDIR /app

# Copy manifests
COPY Cargo.toml Cargo.lock ./

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

RUN apk add --no-cache ca-certificates libgcc

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/target/release/hypo-relay .

# Create non-root user
RUN addgroup -g 1000 hypo && \
    adduser -D -u 1000 -G hypo hypo && \
    chown -R hypo:hypo /app

USER hypo

EXPOSE 8080

CMD ["./hypo-relay"]

