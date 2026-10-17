# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

############################
# profile: the published image. No user and no HOME: a profile adds its own
# user, because Argus runs the agent as the host's uid and gid.
############################
FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS profile

LABEL org.opencontainers.image.source=https://github.com/bxnlabs/argus-containers

ENV DEBIAN_FRONTEND=noninteractive
ENV ARGUS_TOOLS=/opt/argus
ENV PATH=${ARGUS_TOOLS}/bin:${PATH}

# No iptables: tailscaled in netguard runs its firewall in nftables mode, over
# netlink. iproute2 is for the network guard. iputils-ping and netcat-openbsd
# are for raw tailnet traffic from the agent, which routes to the tailnet
# natively. procps gives the agent ps and pkill.
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends --yes \
        ca-certificates \
        curl \
        iproute2 \
        iputils-ping \
        jq \
        netcat-openbsd \
        procps \
    && rm -rf /var/lib/apt/lists/*

# The network guard, netguard's entrypoint.
COPY rootfs/ /

ARG TARGETARCH

# renovate: datasource=github-releases packageName=tailscale/tailscale
ARG TAILSCALE_VERSION=1.104.1

# Tailscale (static binaries: tailscaled runs in netguard; the tailscale CLI
# also works from the agent over the shared socket)
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

# Nothing under the tool prefix is writable by anyone but root, whatever
# modes rootfs/ was checked out with, so no profile user (even one in group 0)
# can replace a tool. Only the entries that need it are touched, which keeps
# this layer small.
# The socket directory is sticky and world-writable, so no profile needs its
# own chown. Profiles bind-mount /var/lib/tailscale on netguard, which hides
# this directory and its mode.
RUN set -eux; \
    find "${ARGUS_TOOLS}" -perm /022 ! -type l -exec chmod go-w {} +; \
    mkdir -p /var/run/tailscale /var/lib/tailscale; \
    chmod 1777 /var/run/tailscale
