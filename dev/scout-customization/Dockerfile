# syntax=docker/dockerfile:1.7
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG RUST_IMAGE=rust:1.96.0-slim-bookworm@sha256:4732ca96fd086cb9be682050c3f0176288eebaac2b80aa2bcefccfaf198e1950
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

FROM ${RUST_IMAGE} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    git \
    libclang-dev \
    libprotobuf-dev \
    libssl-dev \
    libtss2-dev \
    libudev-dev \
    lld \
    pkg-config \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/cargo-home
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV CARGO_TARGET_DIR=/cargo-target

WORKDIR /workspace
COPY . .

RUN --mount=type=cache,id=nico-scout-test-cargo-home,target=/cargo-home,sharing=locked \
    --mount=type=cache,id=nico-scout-test-cargo-target,target=/cargo-target,sharing=locked \
    cargo build --locked --release \
      -p bmc-mock --bin bmc-mock \
      -p carbide-pxe --bin carbide && \
    mkdir -p /artifacts && \
    cp /cargo-target/release/bmc-mock /artifacts/bmc-mock && \
    cp /cargo-target/release/carbide /artifacts/carbide

FROM ${RUNTIME_IMAGE}

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    binutils \
    ca-certificates \
    curl \
    dnsmasq-base \
    iproute2 \
    jq \
    libssl3 \
    libtss2-dev \
    libudev1 \
    libvirt-clients \
    libvirt-daemon-system \
    openssh-client \
    qemu-system-x86 \
    qemu-utils \
    socat \
    sshpass \
    swtpm \
    swtpm-tools \
    tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /artifacts/bmc-mock /usr/local/bin/bmc-mock
COPY --from=builder /artifacts/carbide /usr/local/bin/carbide
COPY crates/bmc-mock/tls.crt /opt/carbide/bmc-tls/tls.crt
COPY crates/bmc-mock/tls.key /opt/carbide/bmc-tls/tls.key
COPY pxe/templates /opt/carbide/pxe/templates
COPY pxe/scout-firmware-scripts /opt/carbide/scout-firmware-scripts
COPY dev/scout-customization/entrypoint.sh /usr/local/bin/nico-scout-lab-entrypoint
COPY dev/scout-customization/network.xml /opt/nico-scout-test/network.xml
COPY dev/scout-customization/domain.xml.tmpl /opt/nico-scout-test/domain.xml.tmpl

EXPOSE 1266 18080 2222

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/nico-scout-lab-entrypoint"]
