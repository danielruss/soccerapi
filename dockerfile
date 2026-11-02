# Build from the workspace root: podman build -t soccerapi -f soccerapi/dockerfile .
# --platform linux/amd64 selects x64; --platform linux/arm64 selects ARM64.
# Keep rustc native to the build host; cross-compile when targeting the other CPU.
FROM --platform=$BUILDPLATFORM rust:1.94-slim-trixie AS builder
ARG TARGETARCH
WORKDIR /app

RUN set -eu; \
    cross_package=""; \
    if [ "$(dpkg --print-architecture)" != "$TARGETARCH" ]; then \
        case "$TARGETARCH" in \
            amd64) cross_package=g++-x86-64-linux-gnu ;; \
            arm64) cross_package=g++-aarch64-linux-gnu ;; \
            *) echo "Unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
        esac; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential $cross_package \
    && rm -rf /var/lib/apt/lists/*

# Official CPU runtime matching ort =2.0.0-rc.12 / api-24.
# Select the archive for the output image, which may differ from the build host.
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) ort_arch=x64; ort_sha256=43725474ba5663642e17684717946693850e2005efbd724ac72da278fead25e6 ;; \
        arm64) ort_arch=aarch64; ort_sha256=6715b3d19965a2a6981e78ed4ba24f17a8c30d2d26420dbed10aac7ceca0085e ;; \
        *) echo "Unsupported ONNX Runtime architecture" >&2; exit 1 ;; \
    esac; \
    curl --fail --location --retry 3 \
        "https://github.com/microsoft/onnxruntime/releases/download/v1.24.2/onnxruntime-linux-${ort_arch}-1.24.2.tgz" \
        --output /tmp/ort.tgz; \
    echo "${ort_sha256}  /tmp/ort.tgz" | sha256sum --check -; \
    mkdir -p /ort; \
    tar -xzf /tmp/ort.tgz -C /ort --strip-components=2 --wildcards '*/lib/*'; \
    rm /tmp/ort.tgz

# ort-sys links against this runtime instead of downloading a static build.
ENV ORT_LIB_PATH=/ort
ENV ORT_PREFER_DYNAMIC_LINK=1
ENV LD_LIBRARY_PATH=/ort

COPY soccerapi/Cargo.toml soccerapi/Cargo.lock ./
COPY soccerapi/src ./src
COPY soccer-cache/Cargo.toml /soccer-cache/Cargo.toml
COPY soccer-cache/README.md /soccer-cache/README.md
COPY soccer-cache/src /soccer-cache/src

# Use the local cache implementation, including its HF_HOME support, even
# though soccer-rs currently depends on the published soccer-cache release.
# Cargo must update the lockfile's registry entry to this local path dependency.
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) rust_target=x86_64-unknown-linux-gnu ;; \
        arm64) rust_target=aarch64-unknown-linux-gnu ;; \
        *) echo "Unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc; \
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc; \
    rustup target add "$rust_target"; \
    printf '\n[patch.crates-io]\nsoccer-cache = { path = "/soccer-cache" }\n' >> Cargo.toml; \
    cargo build --release --bin soccerapi --target "$rust_target"; \
    mkdir -p /out; \
    cp "target/$rust_target/release/soccerapi" /out/soccerapi

FROM debian:trixie-slim
WORKDIR /app

# ONNX Runtime still needs the system C++ runtime. HTTPS downloads need certificates.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    ca-certificates \
    && useradd --create-home --uid 10001 soccer \
    && mkdir -p /cache \
    && chown -R soccer:soccer /cache \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /ort /ort
COPY --from=builder /out/soccerapi ./soccerapi

ENV PORT=8080
ENV ORT_LIB_PATH=/ort
ENV LD_LIBRARY_PATH=/ort
ENV HOME=/home/soccer
# One cache root: Hugging Face uses /cache/hub; SOCcer uses /cache/soccernet.
ENV HF_HOME=/cache
ENV XDG_CACHE_HOME=/cache

# Fail the image build if any native library cannot be resolved.
RUN ldd /app/soccerapi > /tmp/linked-libraries \
    && cat /tmp/linked-libraries \
    && ! grep -q 'not found' /tmp/linked-libraries \
    && rm /tmp/linked-libraries

USER soccer
EXPOSE 8080

CMD ["./soccerapi"]
