# Stage 1: Build
FROM rust:1.94-slim as builder
WORKDIR /app

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY . .

# 1.94's cargo is faster at resolving dependencies
RUN cargo build --release

# Stage 2: Runtime (The tiny version)
FROM debian:trixie-slim
WORKDIR /app

# Install SSL certs in case your app calls other APIs
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the builder stage
COPY --from=builder /app/target/release/soccerapi ./soccerapi

ENV PORT=8080
EXPOSE 8080

CMD ["./soccerapi"]
