# argus-containers

Container images for [Argus](https://github.com/bxnlabs/argus) dockerized profiles.

## `ghcr.io/bxnlabs/argus-containers/profile:main`

A base image with everything a dockerized Argus profile needs:

- Ubuntu 26.04 with a development tool set (build-essential, git, jq, python3, tmux, vim, zsh and more).
- tailscale and tailscaled (userspace networking), pulumi, gcloud (with gsutil and bq), kubectl, helm and oh-my-zsh.
- The agent CLIs Argus supports: `claude`, `codex`, `agy` (Antigravity) and `omp` (oh-my-pi), plus Node.js for the npm-distributed ones.
- A supervisord configuration that seeds `$HOME` and runs tailscaled. tailscaled serves an HTTP and SOCKS5 proxy on `localhost:1055`.
- `/opt/argus/bin/netguard.sh`, `/opt/argus/bin/wait-proxy` and `/opt/argus/etc/env.sh`, described below.

Tools live under `/opt/argus`, which is on `PATH` for every process in the container.

The image has **no user**. It runs as root and does not set `HOME`. Argus runs a profile's agent as the host's uid and gid, which a published image cannot know, so each profile adds its own user.

`:main` is the only tag. CI pushes it for `linux/amd64` and `linux/arm64` on every merge to `main`, after smoke-testing both architectures.

## Profile recipe

A profile lives in `~/.argus/profiles/<name>/` (or `$ARGUS_HOME/profiles/<name>/`):

```
Dockerfile
compose.yaml
.dockerignore
hooks/post_create.sh
.home/          # the profile's isolated HOME
.tailscale/     # the profile's Tailscale state
```

### Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM ghcr.io/bxnlabs/argus-containers/profile:main

# Host-matching identity. Free the uid/gid first (ubuntu ships uid/gid 1000 as
# the `ubuntu` user). HOME points at the mounted host home (-M: reference the
# mount, don't create it).
ARG ARGUS_UID
ARG ARGUS_GID
ARG ARGUS_HOST_HOME
RUN set -eux; \
    if u=$(getent passwd "$ARGUS_UID" | cut -d: -f1); [ -n "$u" ]; then userdel "$u"; fi; \
    if g=$(getent group  "$ARGUS_GID" | cut -d: -f1); [ -n "$g" ]; then groupdel "$g"; fi; \
    groupadd -g "$ARGUS_GID" argus; \
    useradd -u "$ARGUS_UID" -g "$ARGUS_GID" -d "$ARGUS_HOST_HOME" -M -s /usr/bin/zsh argus
ENV HOME=$ARGUS_HOST_HOME
USER argus
```

### compose.yaml

```yaml
x-profile-build: &profile-build
  context: .
  pull: true          # re-pull the FROM image on every build
  args:
    ARGUS_UID: ${ARGUS_UID}
    ARGUS_GID: ${ARGUS_GID}
    ARGUS_HOST_HOME: ${ARGUS_HOST_HOME}

services:
  netguard:
    build: *profile-build
    hostname: my-profile          # the agent shares this container's hostname
    user: root
    entrypoint: ["/opt/argus/bin/netguard.sh"]
    environment:
      NETGUARD_TAILNET_PREFIXES: 100.64.0.0/10
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    sysctls:
      net.ipv6.conf.all.disable_ipv6: 1
    healthcheck:
      test: ["CMD", "/opt/argus/bin/netguard.sh", "--check"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
      start_interval: 1s

  agent:
    build: *profile-build
    network_mode: service:netguard
    depends_on:
      netguard:
        condition: service_healthy
    volumes:
      - ./.home:${ARGUS_HOST_HOME}                                  # isolated HOME
      - ${ARGUS_HOST_HOME}/Workspace:${ARGUS_HOST_HOME}/Workspace   # real Workspace
      - ${ARGUS_STATE_DIR}:${ARGUS_STATE_DIR}                       # Argus state root
      - ./.tailscale:/var/lib/tailscale                             # Tailscale state
    command: ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
```

The service Argus runs sessions in must be named `agent`. `netguard` uses the same `build` block, not `image: ghcr.io/…/profile:main`. That way both services always run the same locally built image, and it changes only when you run `argus profile up`.

Referencing the shared tag directly would be a problem: any pull of it (another profile's refresh, a manual `docker pull`) would make the next lazy start recreate `netguard`, and with it the agent and its live sessions.

`hostname` goes on `netguard` because Docker rejects it on a service that shares another container's network.

### hooks/post_create.sh

```sh
/opt/argus/bin/home-bootstrap.sh >/dev/null 2>&1 || true
/opt/argus/bin/wait-proxy
. /opt/argus/etc/env.sh
echo "[post_create] tailnet traffic goes through tailscaled's proxy on localhost:1055"
```

Argus sources this hook before starting an agent, and before a shell session's login shell. Neither path reads `~/.zshrc` first, so anything agents need in their environment must come from the hook.

The hook seeds `$HOME` itself before anything else. supervisord's `home-bootstrap` does the same at container start, but a session that starts together with the stack can reach its shell first, and zsh then opens its new-user menu on an empty home. `home-bootstrap.sh` only fills in what is missing, so running it twice is harmless.

`wait-proxy` waits up to 10 seconds for tailscaled's proxy, so a session that starts with the stack doesn't race it. On timeout it prints a warning and returns, and the session starts anyway. `env.sh` sets `ALL_PROXY`, `HTTP_PROXY` and `HTTPS_PROXY` (upper and lower case) to `http://localhost:1055`, and `NO_PROXY` to `localhost,127.0.0.1,::1`.

### .dockerignore

```
.home/
.tailscale/
docs/
hooks/
```

### Host directories

Create `.home` and `.tailscale` as yourself before the first start. If either is missing, Docker creates it owned by root, and the profile user can then neither seed its home nor keep a Tailscale login:

```sh
mkdir -p .home .tailscale && chmod 0700 .tailscale
```

### First start and agent logins

```sh
argus profile up <name>
```

Agent credentials and settings are not in the image. They live in the profile's `.home`. Open a shell session in the profile and log in to each agent you use once (`claude`, `codex login`, `agy`, `omp`). The login persists across restarts and image updates.

To join a tailnet, run `tailscale up` in that shell. The login persists in `.tailscale/`.

## Updating a profile

```sh
argus profile up <name>
```

This rebuilds the profile on the latest `:main` (`build.pull: true` re-pulls the base) and recreates the containers when the image changed. **That ends every live session in the profile.** Argus does not refuse when sessions are live, so stop them first. A lazy session start never rebuilds, so nothing changes until you run this command.

## Rolling back

Pin the profile's `FROM` to the digest of an earlier image, then run `argus profile up <name>`:

```dockerfile
FROM ghcr.io/bxnlabs/argus-containers/profile:main@sha256:<digest>
```

To find digests, list the package's versions (each version's `name` is its digest):

```sh
gh api /orgs/bxnlabs/packages/container/argus-containers%2Fprofile/versions \
  --jq '.[] | [.name, .updated_at] | @tsv'
```

The list also holds each image's per-platform and attestation manifests. Pin only a digest for which `docker buildx imagetools inspect ghcr.io/bxnlabs/argus-containers/profile:main@sha256:<digest>` lists both `linux/amd64` and `linux/arm64`.

To keep a record instead, note the digest right after each `argus profile up` on an unpinned `FROM`. It is the image that update built on, unless CI pushed a new one in between. (A pinned profile's digest is the one in its `FROM`.)

```sh
docker buildx imagetools inspect ghcr.io/bxnlabs/argus-containers/profile:main --format '{{.Manifest.Digest}}'
```

Remove the `@sha256:…` pin to follow `:main` again.

## Networking

tailscaled runs in userspace mode without container privileges, so processes in the container reach the tailnet only through its proxy on `localhost:1055`. Anything else goes out directly.

- **HTTP and HTTPS:** clients that honor `HTTP_PROXY`/`HTTPS_PROXY` (curl, most CLIs and SDKs) work unchanged in sessions, because the hook sets them.
- **SOCKS5-aware tools** can use `ALL_PROXY`, or `socks5://localhost:1055` explicitly.
- **Other TCP:** use `tailscale nc`, which dials through tailscaled. For SSH:

  ```sh
  ssh -o ProxyCommand='tailscale nc %h %p' user@host
  ```

  For any other TCP service, use `tailscale nc <host> <port>` as a pipe, or use it as the proxy command of a tool that supports one.

### Network guard

Traffic from the container also has an ordinary path through the Docker bridge and the host. The host routes its own tailnet's addresses out of `tailscale0`, so without a guard, unproxied traffic from the container would reach the host's tailnet peers as the host.

The `netguard` service closes that path. It adds an `unreachable` route for each prefix in `NETGUARD_TAILNET_PREFIXES` (default `100.64.0.0/10`), and it runs with IPv6 disabled. The agent shares its network namespace, and the agent's default capabilities do not include `NET_ADMIN`, so session processes cannot change the routes. The guard is not a security boundary: the agent is trusted, as it is on the host.

If the host accepts subnet routes from its tailnet, add those prefixes to `NETGUARD_TAILNET_PREFIXES`. The e2e preflight checks this.

**If `netguard` stops while the agent keeps running,** the agent is left with no network at all. This fails closed: internet egress is cut too, but no path to the host tailnet opens. `argus profile up` does not repair it, because Compose leaves an unchanged running agent attached to the old namespace. To recover, stop the profile's sessions, then run `argus profile down <name>` and `argus profile up <name>`.

## Agent CLI versions

Each agent CLI is pinned by an `ARG` in the `Dockerfile` and runs at exactly that version:

- `claude`: `DISABLE_AUTOUPDATER=1` in the image environment.
- `codex`: `check_for_update_on_startup = false` in `/etc/codex/config.toml`.
- `agy`: `AGY_CLI_DISABLE_AUTO_UPDATE=true` in the image environment (it ignores `1`).
- `omp`: updates itself only on an explicit `omp update`.

`/opt/argus` is owned by root, so the profile user cannot replace any of them. New versions arrive with image updates.

## Version updates

Renovate keeps the image current and automerges once CI passes. CI builds both architectures and checks that every pinned tool reports its pinned version.

| Dependency | How it is updated |
|---|---|
| `ubuntu`, `alpine/k8s` (kubectl, helm) | Renovate, digest-pinned |
| tailscale, pulumi, omp | Renovate, GitHub releases |
| claude, codex | Renovate, npm |
| Node.js | Renovate within the current major; move majors by hand |
| gcloud | Renovate, through a custom datasource over Google's rapid-channel `components-2.json` |
| agy | By hand: run `.github/scripts/agy-latest` and paste its four `ARG` lines over the `AGY_*` ARGs |
| GitHub Actions | Renovate |
| apt packages, oh-my-zsh | Not pinned: apt packages come from the pinned Ubuntu base's archive at build time; oh-my-zsh is cloned from its default branch |

When Argus supports a new agent CLI, add it to the image and to `.github/scripts/smoke-versions`.

## Tailnet-separation e2e

`e2e/tailnet-separation.sh` proves, through Argus, that a dockerized profile's container joins a tailnet that is not the host's and that the two stay separate. It enrolls a throwaway target node and the profile's agent in a dedicated test tailnet, runs its checks inside a real Argus shell session, and cleans up after itself.

### Prerequisites (once)

1. Create a new tailnet for this test, separate from the host's. Keep MagicDNS enabled (the default).
2. In its access control policy, add:

   ```json
   {
     "tagOwners": { "tag:argus-e2e": ["autogroup:admin"] },
     "grants": [
       { "src": ["tag:argus-e2e"], "dst": ["tag:argus-e2e"], "ip": ["*"] }
     ]
   }
   ```

3. Create an OAuth client with the scopes `auth_keys` (write) and `devices:core` (read and write), restricted to `tag:argus-e2e`.
4. Write `~/.config/argus-e2e/<profile>.env` with mode `0600`:

   ```sh
   TS_E2E_OAUTH_CLIENT_ID=…
   TS_E2E_OAUTH_CLIENT_SECRET=…
   TS_E2E_TAILNET=…          # the test tailnet's name, as `tailscale status --json` reports .CurrentTailnet.Name
   ```

The profile must follow the recipe above: a `netguard` service, a hook that sources `env.sh` and exports `ARGUS_E2E_POST_CREATE`, and a `.tailscale` directory that is logged out (or holds only a login left by an earlier e2e run).

### Running it

```sh
e2e/tailnet-separation.sh --profile acme-test
```

Host requirements: `argus` with a running node, `docker`, `curl`, `jq`, `timeout`, `ss`, `git`, and a host `tailscale` CLI connected to the host's tailnet. If nothing listens on the host's tailnet IP, `python3` is also needed to start a probe listener.

The script prints one `PASS` or `FAIL` line per assertion (A1–A7). It exits 0 only when all pass, 1 when any fails, and 2 when it aborts before its assertions. It aborts in preflight if the host routes any tailnet prefix that the profile's `NETGUARD_TAILNET_PREFIXES` does not cover (subnet routes, or an exit node). Concurrent runs are not supported.
