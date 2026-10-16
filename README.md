# argus-containers

Container images for [Argus](https://github.com/bxnlabs/argus) dockerized profiles.

## `ghcr.io/bxnlabs/argus-containers/profile:main`

The base image for a dockerized Argus profile's compose stack. Sessions run on the host, so the stack has two jobs, and the image holds only what they need:

- `netguard` guards the network and runs tailscaled in TUN mode, with an HTTP and SOCKS5 proxy on port 1055. The image has tailscale, tailscaled and `/opt/argus/bin/netguard.sh`, the service's entrypoint. See [Networking](#networking).
- `agent` is where `argus profile exec --compose` runs tools that need the profile's tailnet natively. The image has `nc`, `ping`, `curl` and `jq` for that, plus the `tailscale` CLI.

Underneath is Ubuntu 26.04, with no agent CLIs, cloud CLIs or development tools. Tools live under `/opt/argus`, which is on `PATH` for every process in the container.

The image has **no user**. It runs as root and does not set `HOME`. Argus runs a profile's agent as the host's user, which a published image cannot know, so each profile adds its own.

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

# Host-matching identity: the host's uid, gid, user name and group name. Free
# each first (ubuntu ships uid/gid 1000 as the `ubuntu` user, and a `staff`
# group with gid 50). HOME points at the mounted host home (-M: reference the
# mount, don't create it). USER is not set by docker exec; `tailscale up`
# needs it to keep the user as tailscaled's operator.
ARG ARGUS_UID
ARG ARGUS_GID
ARG ARGUS_USER
ARG ARGUS_GROUP
ARG ARGUS_HOST_HOME
RUN set -eux; \
    if u=$(getent passwd "$ARGUS_UID" | cut -d: -f1); [ -n "$u" ]; then userdel "$u"; fi; \
    if g=$(getent group  "$ARGUS_GID" | cut -d: -f1); [ -n "$g" ]; then groupdel "$g"; fi; \
    if getent passwd "$ARGUS_USER"  >/dev/null; then userdel  "$ARGUS_USER";  fi; \
    if getent group  "$ARGUS_GROUP" >/dev/null; then groupdel "$ARGUS_GROUP"; fi; \
    groupadd -g "$ARGUS_GID" "$ARGUS_GROUP"; \
    useradd -u "$ARGUS_UID" -g "$ARGUS_GID" -d "$ARGUS_HOST_HOME" -M -s /bin/bash "$ARGUS_USER"
ENV HOME=$ARGUS_HOST_HOME USER=$ARGUS_USER
USER $ARGUS_USER
```

### compose.yaml

```yaml
x-profile-build: &profile-build
  context: .
  pull: true          # re-pull the FROM image on every build
  args:
    ARGUS_UID: ${ARGUS_UID}
    ARGUS_GID: ${ARGUS_GID}
    ARGUS_USER: ${ARGUS_USER:-argus}     # unset on older Argus, or when the lookup fails
    ARGUS_GROUP: ${ARGUS_GROUP:-argus}
    ARGUS_HOST_HOME: ${ARGUS_HOST_HOME}

volumes:
  ts-sock:            # tailscaled's socket, shared with the agent

services:
  netguard:
    build: *profile-build
    hostname: ${ARGUS_HOSTNAME:-my-profile}   # the host's; the agent shares this container's hostname
    user: root
    entrypoint: ["/opt/argus/bin/netguard.sh"]
    environment:
      NETGUARD_TAILNET_PREFIXES: 100.64.0.0/10
      NETGUARD_TS_OPERATOR: ${ARGUS_USER:-argus}   # the agent's user may control tailscaled
      TS_DEBUG_FIREWALL_MODE: nftables             # needs only NET_ADMIN
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv6.conf.all.disable_ipv6: 1
      net.ipv4.conf.all.src_valid_mark: 1
    ports:
      - "127.0.0.1:10551:1055"   # tailnet proxy for host-side sessions; one port per profile
    volumes:
      - ./.tailscale:/var/lib/tailscale   # Tailscale state
      - ts-sock:/var/run/tailscale
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
      - ts-sock:/var/run/tailscale                                  # tailscale CLI
    init: true                    # reaps what `docker exec` leaves behind
    command: ["sleep", "infinity"]
```

The service Argus runs sessions in must be named `agent`. `netguard` uses the same `build` block, not `image: ghcr.io/…/profile:main`. That way both services always run the same locally built image, and it changes only when you run `argus profile up`.

Referencing the shared tag directly would be a problem: any pull of it (another profile's refresh, a manual `docker pull`) would make the next lazy start recreate `netguard`, and with it the agent and its live sessions.

Argus passes `ARGUS_HOST_HOME`, `ARGUS_STATE_DIR`, `ARGUS_UID` and `ARGUS_GID` to every compose invocation. It also passes `ARGUS_USER` (the host login name), `ARGUS_GROUP` (the name of the host user's primary group) and `ARGUS_HOSTNAME` (the host's short hostname), so the agent runs as the host's user on a container named like the host. Those three are best-effort: Argus leaves one unset when its lookup fails, and Argus releases before bxnlabs/argus#197 pass none of them, which is what the recipe's defaults are for.

`hostname` goes on `netguard` because Docker rejects it on a service that shares another container's network. It is also the name `tailscale up` registers the profile under; pass `--hostname` to register a different one.

`netguard` runs tailscaled and keeps its state in `.tailscale`. The agent mounts only tailscaled's socket, so the `tailscale` CLI works there. `NETGUARD_TS_OPERATOR` names the user that may change tailscaled's settings without root, which is the agent's user here; leave it unset and only root in `netguard` can, even if an earlier start set an operator. `tailscale up` keeps the operator only when `$USER` names it, which is why the Dockerfile sets `USER`; without it, the first `tailscale up` clears the operator and `netguard` turns unhealthy. Pick a free host port for each profile's proxy (`10551` above).

### hooks/post_create.sh

Sessions run on the host, and Argus sources this hook in bash before starting an agent, before a shell session's login shell, and for `argus profile exec`. It tells the session where the profile's tailnet proxy is, and points nothing at it:

```sh
export ARGUS_TAILNET_PROXY=http://127.0.0.1:10551   # the port netguard publishes
```

Tools that need the tailnet use the proxy explicitly (see [Networking](#networking)), and everything else goes out directly. The hook doesn't wait for the proxy, because a session shouldn't block on a proxy it may never use.

The hook doesn't export `ALL_PROXY` or `HTTP(S)_PROXY` on purpose. Those would send every HTTP client in the session through `netguard`, including the agent's own API traffic, `git`, `gh` and package managers. The session's network would then depend on the stack being up and healthy. And because the agent is tailscaled's operator, a single `tailscale set --exit-node` would route all of it through the profile's tailnet.

The hook is sourced, so it must not `exit`. Neither session path reads `~/.zshrc` first, so anything agents need in their environment must come from the hook.

### .dockerignore

```
.home/
.tailscale/
docs/
hooks/
```

### Host directories

Create `.home` and `.tailscale` as yourself before the first start. If `.home` is missing, Docker creates it owned by root, and the profile user can't write to it. tailscaled runs in `netguard` as a root without `DAC_OVERRIDE`, so on Linux it can't use a directory another user owns: hand `.tailscale` to root, through a container so it needs no `sudo`:

```sh
mkdir -p .home .tailscale
docker run --rm -v "$PWD/.tailscale:/s" ghcr.io/bxnlabs/argus-containers/profile:main \
  sh -c 'chown -R 0:0 /s && chmod 0700 /s'
```

Run the same `docker run` in a profile that kept its `.tailscale` from before tailscaled moved into `netguard`; that state belongs to the profile user. On macOS, Docker Desktop and OrbStack map ownership on bind mounts, so this step is harmless but not needed.

### First start

```sh
argus profile up <name>
```

Sessions run on the host, so agents use the host user's own installs, credentials and settings in the host's `$HOME`, not the image or the profile's `.home`. The profile's `.home` is the `$HOME` of commands run with `argus profile exec --compose`.

To join a tailnet, run `argus profile exec --compose <name> -- tailscale up`. The login persists in `.tailscale/`.

## Updating a profile

```sh
argus profile up <name>
```

This rebuilds the profile on the latest `:main` (`build.pull: true` re-pulls the base) and recreates the containers when the image changed. **That ends every live session in the profile.** Argus does not refuse when sessions are live, so stop them first. A lazy session start never rebuilds, so nothing changes until you run this command.

An update that changes only the image's configuration, such as an `ENV` line, adds no new layers. Docker's default builder can then reuse a stale copy of the base image's configuration from its build cache, and the profile keeps the old settings. If an update doesn't seem to apply, rebuild once without the cache, then update as usual:

```sh
cd ~/.argus/profiles/<name>
ARGUS_HOST_HOME=$HOME ARGUS_STATE_DIR=$HOME/.argus ARGUS_UID=$(id -u) ARGUS_GID=$(id -g) \
  ARGUS_USER=$(id -un) ARGUS_GROUP=$(id -gn) ARGUS_HOSTNAME=$(hostname -s) \
  docker compose -p argus-<name> build --pull --no-cache
argus profile up <name>
```

To check what the agent got, compare `docker image inspect argus-<name>-agent --format '{{json .Config.Env}}'` with the published image's environment.

## Migrating from the full image

Earlier images also held the agent CLIs, cloud CLIs, development tools and supervisord, and the recipe's `agent` ran `/usr/bin/supervisord`. The current image has no supervisord, so a profile still on that command can't start its `agent` once it is rebuilt on the current `:main`. Docker reports:

```
Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: "/usr/bin/supervisord": stat /usr/bin/supervisord: no such file or directory
```

Migrate each profile in this order:

1. On the image the profile has now, give `agent` `init: true` and `command: ["sleep", "infinity"]` in `compose.yaml`, and change the Dockerfile's `useradd -s` to `/bin/bash`. Run `argus profile up <name>`, then `argus profile exec --compose <name> -- tailscale status`. Both work on the old image.
2. Run `argus profile up <name>` to rebuild on the current `:main`. A lazy session start never rebuilds, so the profile keeps the old image until you do.

Tools the full image had, such as `kubectl`, `gcloud`, `aws`, `git` or `psql`, now run only on the host. If a profile needs one in the stack, add it to the profile's own Dockerfile.

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

tailscaled runs in TUN mode in `netguard`. The agent shares `netguard`'s network namespace, so it reaches the profile's tailnet through ordinary kernel routes: raw TCP, UDP, ICMP and MagicDNS names all work, with no proxy and no capabilities in the agent. Anything else goes out directly.

- **In the stack:** run any tool through `argus profile exec --compose <name> -- …`, for example `argus profile exec --compose <name> -- nc -z db-host 5432`. Raw-TCP tools that can't use a proxy must run this way. The image ships `nc`, `ping`, `curl`, `jq` and `tailscale` for this; anything beyond them, such as `psql`, goes in the profile's own Dockerfile.
- **On the host:** sessions reach the tailnet through tailscaled's HTTP and SOCKS5 proxy, which `netguard` publishes on a loopback port. It listens only on the container's bridge address, not the tailnet address, so the profile's tailnet peers can't use it. The proxy resolves MagicDNS names itself, and passes non-tailnet destinations through to the internet. The hook exports its address as `ARGUS_TAILNET_PROXY`, and only the tools you point at it use it:

  - **kubectl:** set `proxy-url` on each tailnet cluster in the kubeconfig:

    ```yaml
    clusters:
      - name: my-cluster
        cluster:
          server: https://k8s-api.example.ts.net:6443
          proxy-url: http://127.0.0.1:10551
    ```

  - **SSH:** use the proxy as a SOCKS5 proxy, in a `Host` block in `~/.ssh/config`:

    ```
    Host *.example.ts.net
      ProxyCommand nc -X 5 -x 127.0.0.1:10551 %h %p
    ```

    or for one connection:

    ```sh
    ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:10551 %h %p' user@host
    ```

  - **One-off commands:** `HTTPS_PROXY=$ARGUS_TAILNET_PROXY gh api …`, or `curl -x "$ARGUS_TAILNET_PROXY" …`.

  The host's own `tailscale nc` talks to the host's tailnet, not the profile's.

  **When the stack is down,** sessions still start (bxnlabs/argus#235), and only the commands pointed at the proxy fail.

**DNS.** With its default `--accept-dns`, tailscaled rewrites `netguard`'s `/etc/resolv.conf` to use MagicDNS (100.100.100.100), and Docker gives the agent the same file. Short names, tailnet FQDNs and internet names all resolve in the agent with no `dns:` setting.

**IP collisions.** Every tailnet draws addresses from 100.64.0.0/10, so a peer on the profile's tailnet can have the same `100.x` address as one on the host's. In the stack and through the proxy, that address means the profile's peer. Prefer MagicDNS names.

### Network guard

Traffic from the stack also has an ordinary path through the Docker bridge and the host. The host routes its own tailnet's addresses out of its `tailscale0`, so without a guard, traffic from the stack to a `100.x` address the profile's tailnet doesn't have would reach the host's tailnet peers as the host.

`netguard.sh` closes that path before it starts tailscaled. It adds an `unreachable` route for each prefix in `NETGUARD_TAILNET_PREFIXES` (default `100.64.0.0/10`) to the namespace's main routing table, and it requires IPv6 to be disabled. It re-adds the routes on every start, because each start gets a new namespace. tailscaled puts a route for each of the profile's peers into its own table 52, which the kernel consults before the main table. So the profile's peers are reachable, and every other tailnet address hits the guard. That holds for tailscaled's own connections too, so the published proxy can't reach the host's tailnet either.

The agent's default capabilities do not include `NET_ADMIN`, so session processes cannot change the routes. The guard is not a security boundary: the agent is trusted, as it is on the host. The agent shares tailscaled's socket and is its operator, so it has full control of tailscaled: it can run `tailscale up`, `down` and `logout`, accept subnet routes, pick an exit node, or `serve`. Through those it can change the stack's routing without `NET_ADMIN`.

`netguard` needs only `NET_ADMIN` and `/dev/net/tun`. With tailscaled's default firewall backend, iptables, it would also need `NET_RAW`; `TS_DEBUG_FIREWALL_MODE: nftables` avoids that. `net.ipv4.conf.all.src_valid_mark` is set as a service sysctl because tailscaled can't set it inside a container.

If the host accepts subnet routes from its tailnet, add those prefixes to `NETGUARD_TAILNET_PREFIXES`. The e2e preflight checks this.

**If `netguard` restarts while the agent keeps running,** the agent stays in the old namespace with only `lo`. This fails closed: tailnet and internet are both cut, and no path to the host tailnet opens. `tailscale status` in the agent still looks healthy, because the socket reaches the new tailscaled. `argus profile up` and `docker compose up -d` do not repair a restart, because Compose leaves an unchanged running agent attached to the old namespace. Restart the agent: `docker compose -p argus-<name> restart agent` (with the variables Argus passes, as in [Updating a profile](#updating-a-profile)), or stop the profile's sessions and run `argus profile down <name>` and `argus profile up <name>`. After a *recreate* of `netguard`, the next `up` recreates the agent too.

## Version updates

Renovate keeps the image current and automerges once CI passes. CI builds both architectures, checks that tailscale and tailscaled report the pinned version, and fails when the image grows past its size budget in `.github/scripts/smoke-runtime`.

| Dependency | How it is updated |
|---|---|
| `ubuntu` | Renovate, digest-pinned |
| tailscale | Renovate, GitHub releases |
| GitHub Actions | Renovate |
| apt packages | Not pinned: they come from the pinned Ubuntu base's archive at build time |

## Tailnet-separation e2e

`e2e/tailnet-separation.sh` proves, through Argus, that a dockerized profile joins a tailnet that is not the host's and that the two stay separate. It enrolls a throwaway target node and the profile in a dedicated test tailnet, then checks both paths: the agent's native routing, through `argus profile exec --compose`, and the host's published proxy, directly and through `argus profile exec`. It cleans up after itself.

### Prerequisites (once)

1. Create a new tailnet for this test, separate from the host's. Keep MagicDNS enabled (the default).
2. Create an auth key that is **reusable** (the run enrolls two nodes), **ephemeral** (logging out removes a node) and **pre-approved**. Write it to a file with mode `0600`.
3. Pick one peer on the host's tailnet that answers on TCP port 22 from the host. It is the only host-tailnet address the run probes.

The profile must follow the recipe above, with three additions to its `compose.yaml`: a secret named `authkey` that holds the key file, mounted into the agent,

```yaml
secrets:
  authkey:
    file: ${ARGUS_HOST_HOME}/path/to/authkey

services:
  agent:
    secrets: [authkey]
```

and a `.tailscale` directory that is logged out (or holds only a login left by an earlier e2e run).

### Running it

```sh
e2e/tailnet-separation.sh --profile acme-test --host-peer 100.x.y.z
```

The profile's hook must follow the recipe: it exports `ARGUS_TAILNET_PROXY` and no session-wide proxy variables. A7 checks both, and fails against a hook that sets them.

Host requirements: `argus` with a running node, `docker`, `curl`, `jq`, `timeout`, `realpath` (GNU), `python3`, and a host `tailscale` CLI connected to the host's tailnet. It runs on macOS and Linux.

The script prints one `PASS` or `FAIL` line per assertion (A1–A9). It exits 0 only when all pass, 1 when any fails, and 2 when it aborts before its assertions. It aborts in preflight if the host routes any tailnet prefix that the profile's `NETGUARD_TAILNET_PREFIXES` does not cover (accepted subnet routes, or an exit node). A8 restarts and recreates `netguard`. Concurrent runs are not supported. Teardown logs both nodes out on every exit, reports its own failures, and does not change the exit status. If it cannot log the profile out of the test tailnet, the next run stops in preflight until you log the profile out yourself.
