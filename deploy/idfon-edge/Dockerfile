# syntax=docker/dockerfile:1
#
# idfon-edge image. Build from the repo root:
#
#   docker build -f deploy/idfon-edge/Dockerfile -t idfon-edge .
#   docker run --rm idfon-edge --help
#
# The edge links the workspace crates only (idfon-gateway / idfon-h3 / iroh);
# it does not link the vendored iroh-c-ffi dylib, so no native toolchain is
# needed here.

FROM rust:1-bookworm AS build
# aws-lc-rs (the rustls provider the gateway selects) needs cmake to build.
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# `--mount=type=cache,target=/src/target` keeps the ~550-crate iroh build warm
# between builds; the binary must be copied out in this same RUN.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p idfon-edge \
 && cp target/release/idfon-edge /usr/local/bin/idfon-edge

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --home-dir /var/lib/idfon idfon
COPY --from=build /usr/local/bin/idfon-edge /usr/local/bin/idfon-edge
ENV HOME=/var/lib/idfon
USER idfon
WORKDIR /var/lib/idfon
# The default bind is loopback; pass `--bind 0.0.0.0:8080` (and the TLS/token
# flags) for container use. The identity persists in /var/lib/idfon.
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/idfon-edge"]
