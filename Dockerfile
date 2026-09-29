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

# The agent CLIs run the version baked into the image. See README, "Agent CLI
# versions". codex reads its switch from /etc/codex/config.toml (rootfs).
ENV DISABLE_AUTOUPDATER=1
ENV AGY_CLI_DISABLE_AUTO_UPDATE=1

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
# renovate: datasource=node-version packageName=node
ARG NODE_VERSION=24.21.0
# renovate: datasource=npm packageName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.284
# renovate: datasource=npm packageName=@openai/codex
ARG CODEX_VERSION=0.158.0
# renovate: datasource=github-releases packageName=can1357/oh-my-pi
ARG OMP_VERSION=18.4.2
# Antigravity CLI (agy) has no Renovate datasource. Bump these by hand from the
# output of .github/scripts/agy-latest.
ARG AGY_VERSION=1.2.13
ARG AGY_BUILD=6662628811079680
ARG AGY_SHA512_AMD64=7a10134a69c575dc11bdc721322344e9db3bf2c9d890f2d40ff0bffda93d39b6ef1c7c486f491d1ddf08b123deef375c7bbe46b62cd3fbc3cc956b1a3bd22956
ARG AGY_SHA512_ARM64=a26463715b58b787ef24d377138351b725e980c3dec417faa60ad991c8e676f67c6c83b7158d2ef95569a87ba79d0ef2eb781b6d53ac2dbf991f5443f7a46573

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

# Node.js, the runtime for the npm-distributed agent CLIs.
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) N_ARCH=x64 ;; \
        arm64) N_ARCH=arm64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p "${ARGUS_TOOLS}/lib/node"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${N_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C "${ARGUS_TOOLS}/lib/node"; \
    for b in node npm npx; do \
        ln -s "${ARGUS_TOOLS}/lib/node/bin/${b}" "${ARGUS_TOOLS}/bin/${b}"; \
    done

# claude and codex, installed as root under the tool prefix so the profile
# user cannot replace them.
RUN set -eux; \
    npm install --global --prefix "${ARGUS_TOOLS}" --no-fund --no-audit \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}"; \
    npm cache clean --force

# omp (oh-my-pi), checked against the release's SHA256SUMS.txt.
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) O_ARCH=x64 ;; \
        arm64) O_ARCH=arm64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "${base}/omp-linux-${O_ARCH}"; \
    curl -fsSL "${base}/SHA256SUMS.txt" | grep "  omp-linux-${O_ARCH}\$" | sha256sum -c -; \
    install -m 0755 "omp-linux-${O_ARCH}" "${ARGUS_TOOLS}/bin/omp"; \
    rm -f "omp-linux-${O_ARCH}"

# agy (Antigravity CLI), checked against the pinned SHA-512.
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) A_PATH=linux-x64/cli_linux_x64.tar.gz; A_SHA="$AGY_SHA512_AMD64" ;; \
        arm64) A_PATH=linux-arm/cli_linux_arm64.tar.gz; A_SHA="$AGY_SHA512_ARM64" ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/agy.tar.gz \
        "https://storage.googleapis.com/antigravity-public/antigravity-cli/${AGY_VERSION}-${AGY_BUILD}/${A_PATH}"; \
    echo "${A_SHA}  /tmp/agy.tar.gz" | sha512sum -c -; \
    tar -xzf /tmp/agy.tar.gz -C /tmp antigravity; \
    install -m 0755 /tmp/antigravity "${ARGUS_TOOLS}/bin/agy"; \
    rm -f /tmp/agy.tar.gz /tmp/antigravity

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
