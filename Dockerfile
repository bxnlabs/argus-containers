# syntax=docker/dockerfile:1

# kubectl and helm come straight from the upstream k8s image.
FROM alpine/k8s:1.34.3@sha256:f7dbea27672a55bc2b7dd17cdec2d7a03664a7abef9852cbb8be845d9e70c308 AS k8s

############################
# base: OS, dev tools, runtime config
############################
FROM ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78 AS base

LABEL org.opencontainers.image.source=https://github.com/bxnlabs/argus-containers

ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
ENV ARGUS_TOOLS=/opt/argus
ENV PATH=${ARGUS_TOOLS}/bin:${PATH}

RUN mkdir -p ${ARGUS_TOOLS}/bin ${ARGUS_TOOLS}/lib ${ARGUS_TOOLS}/share

# Base development tools. No iptables: userspace Tailscale doesn't touch
# netfilter. iproute2 is for the network guard.
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends --yes \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        less \
        make \
        openssh-client \
        procps \
        python3 \
        supervisor \
        tmux \
        unzip \
        vim \
        wget \
        zsh \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Baked config: supervisor, home bootstrap, network guard, session
# environment, home skeleton.
COPY rootfs/ /

############################
# deps: download CLIs and oh-my-zsh into the tool prefix
############################
FROM base AS deps

ARG TARGETARCH

# renovate: datasource=github-releases packageName=tailscale/tailscale
ARG TAILSCALE_VERSION=1.102.4
# renovate: datasource=github-releases packageName=pulumi/pulumi
ARG PULUMI_VERSION=3.265.0
# renovate: datasource=custom.gcloud packageName=google-cloud-cli
ARG GCLOUD_VERSION=586.0.0

# Tailscale (static binaries: tailscale + tailscaled)
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) TS_ARCH=amd64 ;; \
        arm64) TS_ARCH=arm64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${TS_ARCH}.tgz" \
        | tar -xz --strip-components=1 -C "${ARGUS_TOOLS}/bin" \
            "tailscale_${TAILSCALE_VERSION}_${TS_ARCH}/tailscale" \
            "tailscale_${TAILSCALE_VERSION}_${TS_ARCH}/tailscaled"

# Pulumi
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) P_ARCH=x64 ;; \
        arm64) P_ARCH=arm64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-linux-${P_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C "${ARGUS_TOOLS}/bin"

# Google Cloud SDK (gcloud, gsutil, bq)
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) G_ARCH=x86_64 ;; \
        arm64) G_ARCH=arm ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${G_ARCH}.tar.gz" \
        | tar -xz -C "${ARGUS_TOOLS}/lib"; \
    for b in gcloud gsutil bq; do \
        ln -s "${ARGUS_TOOLS}/lib/google-cloud-sdk/bin/${b}" "${ARGUS_TOOLS}/bin/${b}"; \
    done

# oh-my-zsh (cloned to a system path; $HOME is seeded from it at container start)
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "${ARGUS_TOOLS}/share/oh-my-zsh"

############################
# profile: the published image. No user and no HOME: a profile adds its own
# user, because Argus runs the agent as the host's uid and gid.
############################
FROM base AS profile

COPY --from=k8s /usr/bin/kubectl /usr/bin/helm ${ARGUS_TOOLS}/bin/
COPY --from=deps ${ARGUS_TOOLS}/ ${ARGUS_TOOLS}/

# Runtime directories for whatever non-root UID a profile adds, sticky and
# world-writable so no profile needs its own chown. Profiles bind-mount
# /var/lib/tailscale, which hides this directory and its mode.
RUN set -eux; \
    mkdir -p /var/run/tailscale /var/lib/tailscale "${ARGUS_TOOLS}/share/supervisor"; \
    chmod 1777 /var/run/tailscale "${ARGUS_TOOLS}/share/supervisor"
