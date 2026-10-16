#!/usr/bin/env bash
# Tailnet-separation e2e for a dockerized Argus profile: the profile's
# netguard joins a test tailnet that is not the host's, the agent reaches it
# by native routing, the host reaches it through the published proxy, and
# neither path reaches the host's own tailnet. Prerequisites and usage:
# README.md, "Tailnet-separation e2e".
#
# Usage: e2e/tailnet-separation.sh --profile NAME --host-peer IP [--target-image REF]
#
# --host-peer is the one host-tailnet address the run probes. It must answer
# on TCP port 22 from the host. No other host-tailnet address is contacted.
#
# The target node runs the image of the profile stack's netguard, so both
# sides test the same build. --target-image REF runs it from REF instead.
# Either must be a local image; the run never pulls one.
#
# The auth key comes from the profile's compose secret `authkey`. It must be
# reusable (the run enrolls the target, and the agent twice), ephemeral
# (logout removes them) and pre-approved. The script never reads it.
#
# The profile's post_create hook must follow the README's recipe: it exports
# ARGUS_TAILNET_PROXY and no session-wide proxy variables. A7 checks both.
#
# Exit status: 0 when every assertion passes, 1 when any fails, and 2 when the
# run aborts before its assertions.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_COMPOSE=$REPO_ROOT/e2e/target/compose.yaml
POSTGRES_IMAGE=postgres:16-alpine
HOST_PEER_PORT=22
DEADLINE=60     # bound for polls, in seconds
API_DEADLINE=15 # bound for a single status call
STEP_TIMEOUT=30 # bound for each argus, docker and compose call
STACK_TIMEOUT=900 # bound for the calls that first bring up the stack (it may build) and the target
DEFAULT_GUARD_PREFIXES=100.64.0.0/10

log() { printf '[e2e] %s\n' "$*" >&2; }
die() {
  printf '[e2e] ABORT: %s\n' "$*" >&2
  exit 2
}

# resolve_state_dir: the Argus state root, by Argus's rules (shared.StateDir):
# ARGUS_HOME if set, with a leading ~ expanded and a relative path rejected,
# otherwise $HOME/.argus.
resolve_state_dir() {
  local dir=${ARGUS_HOME:-}
  if [[ -z $dir ]]; then
    printf '%s\n' "$HOME/.argus"
    return 0
  fi
  if [[ $dir == '~'* ]]; then
    dir=$HOME/${dir:1}
  fi
  if [[ $dir != /* ]]; then
    printf 'ARGUS_HOME must be an absolute path or start with ~, got %q\n' "$ARGUS_HOME" >&2
    return 1
  fi
  realpath -ms -- "$dir"
}

# find_compose_file DIR: the profile's compose file, in Compose's order.
find_compose_file() {
  local name
  for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f $1/$name ]]; then
      printf '%s\n' "$1/$name"
      return 0
    fi
  done
  return 1
}

ip4_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
  ((a < 256 && b < 256 && c < 256 && d < 256)) || return 1
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

# cidr_covers OUTER INNER: succeed when every address in INNER is in OUTER.
# A bare address counts as a /32.
cidr_covers() {
  local on=${1%/*} ol=32 in=${2%/*} il=32 o i mask
  [[ $1 == */* ]] && ol=${1#*/}
  [[ $2 == */* ]] && il=${2#*/}
  o=$(ip4_to_int "$on") || return 1
  i=$(ip4_to_int "$in") || return 1
  ((il >= ol)) || return 1
  mask=$((ol == 0 ? 0 : (0xFFFFFFFF << (32 - ol)) & 0xFFFFFFFF))
  (((o & mask) == (i & mask)))
}

# host_routes STATUS_JSON ROUTE_ALL: print each IPv4 destination the host
# routes into its tailnet beyond its peers' own addresses: the subnet routes
# its peers serve, unless ROUTE_ALL is "false" (the host does not accept
# them), and 0.0.0.0/0 when it uses an exit node.
host_routes() {
  jq -r --arg ra "$2" '
    ((if $ra == "false" then [] else [.Peer[]?.PrimaryRoutes[]?] end)
      + (if .ExitNodeStatus then ["0.0.0.0/0"] else [] end))
    | .[] | select(test(":") | not)' <<<"$1"
}

# uncovered_routes PREFIXES: read one destination per line on stdin and print
# each that no prefix in PREFIXES (commas or whitespace between them) covers.
uncovered_routes() {
  local dst p covered raw=${1//$'\n'/ }
  local -a prefixes
  # Parse PREFIXES as netguard.sh does, newlines included.
  read -r -a prefixes <<<"${raw//,/ }"
  while read -r dst; do
    [[ -n $dst ]] || continue
    covered=0
    for p in "${prefixes[@]}"; do
      if cidr_covers "$p" "$dst"; then
        covered=1
        break
      fi
    done
    ((covered)) || printf '%s\n' "$dst"
  done
}

# classify_login JSON HOST_TAILNET: classify a running profile's Tailscale
# login from `tailscale status --json`. Prints logged-out, e2e (a login an
# earlier e2e run left behind on a tailnet other than the host's), or foreign
# (anything else, including unparseable input).
classify_login() {
  local out
  out=$(jq -r --arg host_tn "$2" '
    (.CurrentTailnet.Name // "") as $cur
    | (.Self.HostName // "") as $host
    | if ((.BackendState == "NeedsLogin" or .BackendState == "NoState") and $cur == "") then "logged-out"
      elif ($cur != "" and $cur != $host_tn and ($host | test("^argus-e2e-agent-[0-9a-f]{8}$"))) then "e2e"
      else "foreign" end' <<<"$1" 2>/dev/null)
  printf '%s\n' "${out:-foreign}"
}

# proxy_port CONFIG_JSON: the host port that publishes netguard's port 1055
# on 127.0.0.1, from `docker compose config --format json`.
proxy_port() {
  jq -er '[.services.netguard.ports[]?
    | select((.target | tostring) == "1055" and .host_ip == "127.0.0.1")
    | .published | tostring][0] // empty' <<<"$1"
}

# authkey_file CONFIG_JSON: the file behind the compose secret `authkey`,
# when the agent service mounts it.
authkey_file() {
  jq -er 'select(any(.services.agent.secrets[]?; .source == "authkey")) | .secrets.authkey.file // empty' <<<"$1"
}

# is_target_project NAME: whether NAME is a target compose project this
# script generates. recover removes only these.
is_target_project() { [[ $1 =~ ^e2e-tailnet-target-[0-9a-f]{8}$ ]]; }

# tmpl TEMPLATE [NAME VALUE]...: replace each @NAME@ in TEMPLATE with VALUE,
# literally.
tmpl() {
  local s=$1
  shift
  while (($# >= 2)); do
    s=${s//"@$1@"/"$2"}
    shift 2
  done
  printf '%s' "$s"
}

q() { printf '%q' "$1"; }

# unreachable_cmd HOST PORT: a command for the agent that exits 0 only when a
# TCP connect to HOST:PORT fails with EHOSTUNREACH or ENETUNREACH. A connect,
# a refusal or a timeout fails it. It uses bash's /dev/tcp, because the image
# has no python3.
# shellcheck disable=SC2016 # expands in the agent
unreachable_cmd() {
  tmpl 'out=$(timeout 5 bash -c "exec 3<>/dev/tcp/@H@/@P@" 2>&1); rc=$?; printf "rc=%s %s\n" "$rc" "$out"; [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && printf "%s" "$out" | grep -qiE "no route to host|network is unreachable"' H "$1" P "$2"
}

# PROBE: a TCP probe, run with python3 on the host.
#   connect HOST PORT              exit 0 when it connects, 1 when refused or
#                                  unreachable, 2 on a timeout or other error
#   socks HOST PORT PROXY_PORT     SOCKS5 CONNECT through 127.0.0.1:PROXY_PORT
#   http HOST PORT PROXY_PORT      HTTP CONNECT through 127.0.0.1:PROXY_PORT
# The proxy modes exit 0 when the proxy connects, 1 when it answers with a
# refusal, and 2 when it does not answer.
# shellcheck disable=SC2016 # Python, not shell
PROBE='
import errno, socket, sys
mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
def done(msg, rc):
    print(msg)
    sys.exit(rc)
if mode == "connect":
    s = socket.socket()
    s.settimeout(5)
    try:
        r = s.connect_ex((host, port))
    except socket.timeout:
        done("timeout", 2)
    name = errno.errorcode.get(r, r) if r else "connected"
    done(name, 0 if r == 0 else (1 if r in (errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.ENETUNREACH) else 2))
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[4])), timeout=15)
    if mode == "socks":
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            done("no SOCKS5 greeting", 2)
        s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(host) + port.to_bytes(2, "big"))
        r = s.recv(10)
        if len(r) < 2:
            done("no SOCKS5 reply", 2)
        done("socks reply %d" % r[1], 0 if r[1] == 0 else 1)
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % (host, port, host, port)).encode())
    line = s.makefile("rb").readline().decode(errors="replace").strip()
    if not line:
        done("no HTTP reply", 2)
    done(line, 0 if line.split()[1:2] == ["200"] else 1)
except OSError as e:
    done("error: %s" % e, 2)
'

parse_args() {
  PROFILE="" HOST_PEER="" TARGET_IMAGE_REF=""
  local flag value
  while (($#)); do
    case $1 in
      --profile | --host-peer | --target-image)
        (($# >= 2)) || die "$1 needs a value"
        flag=$1 value=$2
        shift 2
        ;;
      --profile=* | --host-peer=* | --target-image=*)
        flag=${1%%=*} value=${1#*=}
        shift
        ;;
      -h | --help)
        # The header comment, up to the first line that isn't one.
        awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"
        exit 0
        ;;
      *) die "unknown argument: $1" ;;
    esac
    case $flag in
      --profile) PROFILE=$value ;;
      --host-peer) HOST_PEER=$value ;;
      --target-image)
        [[ -n $value ]] || die "--target-image needs a value"
        TARGET_IMAGE_REF=$value
        ;;
    esac
  done
  [[ -n $PROFILE && -n $HOST_PEER ]] || die "usage: $0 --profile NAME --host-peer IP [--target-image REF]"
  [[ $PROFILE =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $PROFILE"
  if [[ $HOST_PEER == */* ]] || ! cidr_covers 100.64.0.0/10 "$HOST_PEER"; then
    die "--host-peer must be a tailnet IPv4 address in 100.64.0.0/10, got $HOST_PEER"
  fi
}

init_run() {
  ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) || die "bash 5.1 or later is required"
  STATE_DIR=$(resolve_state_dir) || die "cannot resolve the Argus state root"
  PROFILE_DIR=$STATE_DIR/profiles/$PROFILE
  RUN_ID=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  TARGET_PROJECT=e2e-tailnet-target-$RUN_ID
  AGENT_HOST=argus-e2e-agent-$RUN_ID
  # Teardown acts only on what these record as this run's.
  TARGET_STARTED=0 OWN_LOGIN=0 STACK_WAS_UP=0 TEARDOWN_ERRORS=0
  TARGET_IP="" TARGET_NAME="" OUT="" LOGIN_STATUS="" TS_OPERATOR="" TARGET_IMAGE=""
}

# compose ARGS...: docker compose against the profile's stack, with the
# variables Argus passes, bounded by STEP_TIMEOUT (or -t SECONDS).
compose() {
  local t=$STEP_TIMEOUT
  if [[ $1 == -t ]]; then
    t=$2
    shift 2
  fi
  ARGUS_HOST_HOME=$HOME ARGUS_STATE_DIR=$STATE_DIR ARGUS_UID=$(id -u) ARGUS_GID=$(id -g) \
    ARGUS_USER=$(id -un) ARGUS_GROUP=$(id -gn) ARGUS_HOSTNAME=$(hostname -s) \
    timeout "$t" docker compose -p "argus-$PROFILE" -f "$COMPOSE_FILE" "$@"
}

# compose_target [-t SECONDS] PROJECT ARGS...: docker compose against a target
# project, bounded by STEP_TIMEOUT (or -t SECONDS).
compose_target() {
  local t=$STEP_TIMEOUT project
  if [[ $1 == -t ]]; then
    t=$2
    shift 2
  fi
  project=$1
  shift
  E2E_KEY_FILE=$KEY_FILE E2E_TARGET_IMAGE=$TARGET_IMAGE E2E_POSTGRES_IMAGE=$POSTGRES_IMAGE \
    NONCE=$NONCE RUN_ID=$RUN_ID \
    timeout "$t" docker compose -p "$project" -f "$TARGET_COMPOSE" "$@"
}

# in_stack [-t SECONDS] CMD: run CMD with bash in the profile stack's agent
# service through `argus profile exec --compose`, as the agent's user. Sets
# OUT to its output and returns its status. The working directory is $HOME,
# which every profile mounts.
in_stack() {
  local t=$STEP_TIMEOUT
  if [[ $1 == -t ]]; then
    t=$2
    shift 2
  fi
  OUT=$(cd "$HOME" && timeout "$t" argus profile exec --compose "$PROFILE" -- bash -c "$1" </dev/null 2>&1)
}

# on_host_hooked CMD: run CMD with bash on the host in the profile's
# environment (its post_create hook sourced, as for a session) through
# `argus profile exec`. Sets OUT and returns CMD's status.
on_host_hooked() {
  OUT=$(cd "$HOME" && timeout "$STEP_TIMEOUT" argus profile exec "$PROFILE" -- bash -c "$1" </dev/null 2>&1)
}

# wait_until SECONDS CMD...: rerun CMD every 2 seconds until it succeeds or
# SECONDS pass. CMD runs in this shell, so its side effects persist.
wait_until() {
  local end=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < end)) || return 1
    sleep 2
  done
}

netguard_status() {
  compose exec -T netguard tailscale status --json 2>/dev/null
}

# caps_exactly_net_admin STATUS: /proc/<pid>/status text has CapEff and
# CapBnd both exactly CAP_NET_ADMIN (bit 12).
caps_exactly_net_admin() {
  local eff bnd
  eff=$(awk '$1 == "CapEff:" { print $2 }' <<<"$1")
  bnd=$(awk '$1 == "CapBnd:" { print $2 }' <<<"$1")
  [[ $eff == 0000000000001000 && $bnd == 0000000000001000 ]]
}

# netguard_caps: netguard's entrypoint runs with exactly NET_ADMIN.
netguard_caps() {
  local st
  st=$(compose exec -T netguard cat /proc/1/status) || return 1
  caps_exactly_net_admin "$st" && return 0
  grep -E '^Cap(Eff|Bnd):' <<<"$st"
  return 1
}

netguard_healthy() {
  compose exec -T netguard /opt/argus/bin/netguard.sh --check >/dev/null 2>&1
}

# logout_owned_login: end the run's login as root in netguard. Kill any
# `tailscale up` still running in the agent, restart tailscaled (netguard,
# then the agent, which would otherwise keep the old network namespace) so an
# enrollment pending inside the daemon is abandoned rather than completing
# later, then log out. (logout alone returns early when no node key exists
# yet, without cancelling a pending login.) The restarts are best-effort: the
# logout is always attempted, and any failure is reported at the end.
logout_owned_login() {
  local state errs=()
  compose exec -T agent pkill -f '[t]ailscale up --auth-key' >/dev/null 2>&1
  compose restart -t 5 netguard >/dev/null 2>&1 || errs+=("restarting netguard failed")
  compose restart -t 5 agent >/dev/null 2>&1 || errs+=("restarting the agent failed")
  wait_until "$DEADLINE" netguard_healthy || errs+=("netguard did not become healthy after its restart")
  compose exec -T netguard tailscale logout >/dev/null 2>&1
  state=$(netguard_status | jq -r .BackendState 2>/dev/null)
  [[ $state == NeedsLogin || $state == NoState ]] || errs+=("tailscale is still ${state:-unreadable}")
  ((${#errs[@]} == 0)) && return 0
  local IFS=';'
  echo "${errs[*]}"
  return 1
}

# logout_target PROJECT: log a target node out, which removes it from the
# tailnet because its key is ephemeral, then remove the project.
logout_target() {
  local rc=0
  compose_target "$1" exec -T node tailscale logout >/dev/null || rc=1
  compose_target "$1" down -v -t 1 --remove-orphans >/dev/null || rc=1
  return "$rc"
}

preflight_checks() {
  local c uncovered services route_all host_routes_list
  for c in argus docker curl jq timeout tailscale python3 od realpath; do
    command -v "$c" >/dev/null || die "missing host command: $c"
  done

  timeout "$STEP_TIMEOUT" argus session ls --json >/dev/null 2>&1 || die "the Argus node does not answer"
  [[ $(timeout "$STEP_TIMEOUT" argus profile ls 2>/dev/null | awk -v p="$PROFILE" '$1 == p { print $2 }') == docker ]] ||
    die "$PROFILE is not a dockerized Argus profile"
  COMPOSE_FILE=$(find_compose_file "$PROFILE_DIR") || die "no compose file in $PROFILE_DIR"
  CONFIG_JSON=$(compose config --format json 2>/dev/null) || die "docker compose config failed for $COMPOSE_FILE"
  jq -e '.services.netguard and .services.agent' >/dev/null <<<"$CONFIG_JSON" ||
    die "$COMPOSE_FILE needs a netguard and an agent service"
  GUARD_PREFIXES=$(jq -r --arg d "$DEFAULT_GUARD_PREFIXES" '.services.netguard.environment.NETGUARD_TAILNET_PREFIXES // $d' <<<"$CONFIG_JSON")
  TS_OPERATOR=$(jq -r '.services.netguard.environment.NETGUARD_TS_OPERATOR // empty' <<<"$CONFIG_JSON")
  [[ -n $TS_OPERATOR ]] || die "netguard does not set NETGUARD_TS_OPERATOR, so the agent cannot run tailscale up"
  PROXY_PORT=$(proxy_port "$CONFIG_JSON") || die "netguard does not publish port 1055 on 127.0.0.1"
  KEY_FILE=$(authkey_file "$CONFIG_JSON") || die "the agent does not mount a compose secret named authkey"
  [[ -f $KEY_FILE && -r $KEY_FILE ]] || die "the authkey secret's file $KEY_FILE is missing or unreadable"
  [[ -n $(find "$KEY_FILE" -prune -perm 600) ]] || die "$KEY_FILE must have mode 0600"

  HOST_STATUS=$(timeout "$API_DEADLINE" tailscale status --json 2>/dev/null) || die "host tailscale status failed"
  [[ $(jq -r .BackendState <<<"$HOST_STATUS") == Running ]] || die "the host is not connected to its tailnet"
  HOST_TAILNET=$(jq -r '.CurrentTailnet.Name // empty' <<<"$HOST_STATUS")
  [[ -n $HOST_TAILNET ]] || die "cannot read the host's tailnet name"
  HOST_DNS_SUFFIX=$(jq -r '.CurrentTailnet.MagicDNSSuffix // .MagicDNSSuffix // empty' <<<"$HOST_STATUS")
  HOST_IPS_JSON=$(jq -c '[.Self.TailscaleIPs[]?, .Peer[]?.TailscaleIPs[]?]' <<<"$HOST_STATUS")
  [[ -n $HOST_DNS_SUFFIX ]] || die "cannot read the host's MagicDNS suffix"
  jq -e --arg ip "$HOST_PEER" 'any(.Peer[]?.TailscaleIPs[]?; . == $ip)' >/dev/null <<<"$HOST_STATUS" ||
    die "--host-peer $HOST_PEER is not a peer on the host's tailnet"
  log "host tailnet $HOST_TAILNET; host peer $HOST_PEER; proxy 127.0.0.1:$PROXY_PORT"
  [[ -z $TARGET_IMAGE_REF ]] || target_image_from_flag

  # Without the prefs (an older CLI), assume the host accepts subnet routes.
  route_all=$(timeout "$API_DEADLINE" tailscale debug prefs 2>/dev/null | jq -r '.RouteAll | values' 2>/dev/null)
  host_routes_list=$(host_routes "$HOST_STATUS" "${route_all:-true}") || die "cannot read the host's tailnet routes"
  uncovered=$(uncovered_routes "$GUARD_PREFIXES" <<<"$host_routes_list")
  [[ -z $uncovered ]] ||
    die "host tailnet routes not covered by NETGUARD_TAILNET_PREFIXES=$GUARD_PREFIXES: $(tr '\n' ' ' <<<"$uncovered")"

  services=$(compose ps --status running --services) || die "cannot read the profile's stack state"
  if grep -qx netguard <<<"$services"; then
    STACK_WAS_UP=1
  fi
  log "stack was $( ((STACK_WAS_UP)) && echo up || echo down ) before the test"
}

# login_settled: tailscaled has loaded any saved login. Sets LOGIN_STATUS.
login_settled() {
  LOGIN_STATUS=$(netguard_status) &&
    jq -e '.BackendState != "NoState" and .BackendState != "Starting"' >/dev/null <<<"$LOGIN_STATUS"
}

# local_image_id REF: the ID of the local image REF. It never pulls.
local_image_id() {
  local id
  id=$(timeout "$STEP_TIMEOUT" docker image inspect -f '{{.Id}}' -- "$1" 2>/dev/null) && [[ -n $id ]] || return 1
  printf '%s\n' "$id"
}

# target_image_from_flag: run the target from the local image --target-image
# names, by its ID.
target_image_from_flag() {
  TARGET_IMAGE=$(local_image_id "$TARGET_IMAGE_REF") ||
    die "--target-image $TARGET_IMAGE_REF is not a local image; pull or build it first"
  log "target image $TARGET_IMAGE_REF ($TARGET_IMAGE), from --target-image"
}

# target_image_from_netguard: run the target from the image the profile
# stack's running netguard container runs, by its ID, so the target has the
# profile's build of tailscaled and the target's tools.
target_image_from_netguard() {
  local cid ref id
  cid=$(compose ps -q netguard)
  [[ -n $cid ]] || die "cannot find the profile stack's netguard container"
  read -r ref id < <(timeout "$STEP_TIMEOUT" docker inspect -f '{{.Config.Image}} {{.Image}}' "$cid" 2>/dev/null)
  if [[ -z $id ]] || ! local_image_id "$id" >/dev/null; then
    die "netguard's image ${ref:-(unreadable)} ${id:+($id) }is not a local image"
  fi
  TARGET_IMAGE=$id
  log "target image $ref ($id), the profile's netguard image"
}

# recover: bring the stack up, refuse a login this e2e does not own, and clean
# up after earlier crashed runs. tailscaled's state is root's, so its login is
# read from the running daemon; teardown stops a stack that was down.
recover() {
  local projects p
  log "bringing the profile's stack up through Argus"
  in_stack -t "$STACK_TIMEOUT" true || die "argus profile exec --compose failed: $OUT"
  # Before removing leftover targets: their compose file needs an image.
  [[ -n $TARGET_IMAGE_REF ]] || target_image_from_netguard
  wait_until "$DEADLINE" login_settled || die "tailscaled never loaded its state: $LOGIN_STATUS"
  case $(classify_login "$LOGIN_STATUS" "$HOST_TAILNET") in
    logged-out) ;;
    e2e)
      log "logging out a login left by an earlier e2e run"
      OWN_LOGIN=1
      logout_owned_login || die "could not log out the abandoned e2e login"
      ;;
    *) die "the profile is logged in to a tailnet this e2e does not own; log it out first (tailscale logout)" ;;
  esac
  projects=$(timeout "$STEP_TIMEOUT" docker compose ls -a --format json | jq -r '.[].Name') ||
    die "listing compose projects failed"
  local leftovers=()
  for p in $projects; do
    is_target_project "$p" && leftovers+=("$p")
  done
  remove_leftover_targets "${leftovers[@]}" || die "could not remove a leftover target project"
}

# remove_leftover_targets PROJECT...: remove target projects left by earlier
# runs. A node whose container has exited can't be logged out; its key is
# ephemeral, so the tailnet removes it once it is offline. Fails only when a
# project can't be removed.
remove_leftover_targets() {
  local p
  for p in "$@"; do
    log "removing leftover target project $p"
    compose_target "$p" exec -T node tailscale logout >/dev/null 2>&1 ||
      log "could not log $p's node out; removing the project anyway"
    compose_target "$p" down -v -t 1 --remove-orphans >/dev/null || return 1
  done
}

target_ready() {
  local st
  st=$(compose_target "$TARGET_PROJECT" exec -T node tailscale status --json 2>/dev/null) || return 1
  [[ $(jq -r '.BackendState // empty' <<<"$st") == Running ]] || return 1
  [[ $(compose_target "$TARGET_PROJECT" exec -T node curl -fsS --max-time 5 http://localhost:8080/ 2>/dev/null) == "$NONCE" ]] || return 1
  compose_target "$TARGET_PROJECT" exec -T postgres pg_isready -q -h 127.0.0.1 >/dev/null 2>&1 || return 1
  TARGET_IP=$(jq -r '[.Self.TailscaleIPs[]? | select(test("^[0-9.]+$"))][0] // empty' <<<"$st")
  # Stale nodes can hold the bare hostname, so read the name the node got.
  TARGET_NAME=$(jq -r '(.Self.DNSName // "") | split(".")[0]' <<<"$st")
  [[ -n $TARGET_IP && -n $TARGET_NAME ]]
}

start_target() {
  log "starting target project $TARGET_PROJECT"
  TARGET_STARTED=1
  # The first start may pull the images.
  OUT=$(compose_target -t "$STACK_TIMEOUT" "$TARGET_PROJECT" up -d 2>&1) || {
    log "docker compose up for the target failed: $OUT"
    return 1
  }
  if ! wait_until "$DEADLINE" target_ready; then
    log "the target never reported Running and served the nonce and PostgreSQL; its last log lines:"
    compose_target "$TARGET_PROJECT" logs --tail 30 >&2
    return 1
  fi
  if jq -e --arg ip "$TARGET_IP" 'any(.[]; . == $ip)' >/dev/null <<<"$HOST_IPS_JSON"; then
    log "the target got $TARGET_IP, which a host-tailnet node also has; rerun"
    return 1
  fi
  log "target $TARGET_NAME ($TARGET_IP)"
}

# agent_up: log in from the agent with the authkey secret. Sets OUT.
agent_up() {
  in_stack -t 60 "timeout -k 5 45 tailscale up --auth-key=file:/run/secrets/authkey --hostname=$AGENT_HOST"
}

daemon_needs_login() {
  in_stack -t "$API_DEADLINE" 'tailscale status --json | jq -e ".BackendState == \"NeedsLogin\"" >/dev/null'
}

agent_logged_in() {
  # shellcheck disable=SC2016 # expands in the agent
  in_stack -t "$API_DEADLINE" "$(tmpl 'tailscale status --json | jq -e --arg h @H@ ".Self.HostName == \$h and .BackendState == \"Running\"" >/dev/null' H "$AGENT_HOST")"
}

start_agent() {
  wait_until "$DEADLINE" daemon_needs_login ||
    { log "tailscaled never reported NeedsLogin: $OUT"; return 1; }
  # From here on, any login in the profile is this run's: recover saw it
  # logged out, or logged out the abandoned e2e login.
  OWN_LOGIN=1
  log "enrolling $AGENT_HOST from the agent"
  agent_up || { log "tailscale up from the agent failed: $OUT"; return 1; }
  wait_until "$DEADLINE" agent_logged_in || { log "the agent never came up as $AGENT_HOST: $OUT"; return 1; }
}

ASSERT_FAILED=0
CHECK_OUT=""

# assert ID DESCRIPTION CMD...: run one assertion and print its verdict.
assert() {
  local id=$1 desc=$2
  shift 2
  CHECK_OUT=""
  if "$@"; then
    printf 'PASS %s %s\n' "$id" "$desc"
  else
    ASSERT_FAILED=1
    printf 'FAIL %s %s\n' "$id" "$desc"
    [[ -n $CHECK_OUT ]] && printf '%s\n' "$CHECK_OUT" | sed 's/^/    /'
  fi
}

# stack_step LABEL CMD: one step of an assertion, run in the agent. On
# failure its label, status and output go into CHECK_OUT.
stack_step() {
  local rc
  in_stack "$2"
  rc=$?
  if ((rc != 0)); then
    CHECK_OUT+="$1 (rc=$rc):"$'\n'"$OUT"$'\n'
    return 1
  fi
}

# hooked_step LABEL CMD: one step of an assertion, run on the host in the
# profile's environment.
hooked_step() {
  local rc
  on_host_hooked "$2"
  rc=$?
  if ((rc != 0)); then
    CHECK_OUT+="$1 (rc=$rc):"$'\n'"$OUT"$'\n'
    return 1
  fi
}

# on_host LABEL CMD...: one step of an assertion, run on the host.
on_host() {
  local label=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  if ((rc != 0)); then
    CHECK_OUT+="$label (rc=$rc):"$'\n'"$out"$'\n'
    return 1
  fi
}

# expect_rc WANT CMD...: succeed when CMD exits WANT, printing its output.
expect_rc() {
  local want=$1 rc
  shift
  "$@"
  rc=$?
  ((rc == want)) || {
    echo "exit $rc, want $want"
    return 1
  }
}

probe() { python3 -I -c "$PROBE" "$@"; }

# shellcheck disable=SC2016 # these commands expand in the agent
a1_joined_as_operator() {
  local failed=0
  stack_step "the agent runs as the host's uid" "$(tmpl 'u=$(id -u); printf "uid=%s\n" "$u"; [ "$u" = @U@ ]' U "$(id -u)")" || failed=1
  stack_step "joined $AGENT_HOST on a tailnet other than the host's" "$(tmpl 's=$(tailscale status --json); printf "%s\n" "$s" | jq -c "{BackendState, tailnet: .CurrentTailnet.Name, host: .Self.HostName}"; printf "%s\n" "$s" | jq -e --arg h @H@ --arg host_tn @TN@ ".BackendState == \"Running\" and .Self.HostName == \$h and (.CurrentTailnet.Name // \"\") != \"\" and .CurrentTailnet.Name != \$host_tn" >/dev/null' \
    H "$AGENT_HOST" TN "$(q "$HOST_TAILNET")")" || failed=1
  stack_step "tailscale set works from the agent" 'tailscale set --accept-routes=false' || failed=1
  on_host "netguard has exactly NET_ADMIN" netguard_caps || failed=1
  stack_step "no firewall health warnings" 'h=$(tailscale status --json | jq -r ".Health[]?"); printf "%s\n" "$h"; ! printf "%s\n" "$h" | grep -qiE "firewall|netfilter|iptables|nftables"' || failed=1
  return "$failed"
}

# shellcheck disable=SC2016 # these commands expand in the agent
a2_agent_reaches_peer() {
  local failed=0 h
  # CAP_NET_ADMIN is bit 12. Without it in the bounding set, no process in
  # the agent can gain it, root or not.
  stack_step "the agent lacks NET_ADMIN" 'for f in CapEff CapBnd; do c=$(awk -v f="$f:" "\$1 == f {print \$2}" /proc/self/status); printf "%s=%s\n" "$f" "$c"; [ -n "$c" ] && [ $(( (0x$c >> 12) & 1 )) -eq 0 ] || exit 1; done' || failed=1
  stack_step "the agent has no proxy variables" 'v=$(env | grep -iE "^(all|http|https)_proxy="); printf "%s\n" "$v"; [ -z "$v" ]' || failed=1
  for h in "$TARGET_IP" "$TARGET_NAME"; do
    stack_step "nc to $h:5432" "nc -z -w 10 $h 5432" || failed=1
    stack_step "ping $h" "ping -c 2 -W 5 $h" || failed=1
    stack_step "curl http://$h:8080/" "$(tmpl 'r=$(curl -fsS --max-time 15 http://@H@:8080/); printf "got=%s\n" "$r"; [ "$r" = @N@ ]' H "$h" N "$NONCE")" || failed=1
  done
  return "$failed"
}

# Positive controls from the host, immediately before each negative probe:
# the host peer is there and answers.
host_peer_controls() {
  local failed=0
  on_host "control: the host connects to $HOST_PEER:$HOST_PEER_PORT" probe connect "$HOST_PEER" "$HOST_PEER_PORT" || failed=1
  on_host "control: the host pings $HOST_PEER over its tailnet" \
    timeout 20 tailscale ping --until-direct=false -c 1 --timeout 5s "$HOST_PEER" || failed=1
  return "$failed"
}

# shellcheck disable=SC2016 # these commands expand in the agent
a3_agent_no_host_tailnet() {
  local failed=0
  host_peer_controls || failed=1
  stack_step "ip route get $HOST_PEER is unreachable" "$(tmpl 'out=$(ip route get @IP@ 2>&1); rc=$?; printf "%s\n" "$out"; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -qiE "unreachable|no route to host"' IP "$HOST_PEER")" || failed=1
  stack_step "direct connect to $HOST_PEER:$HOST_PEER_PORT is unreachable" "$(unreachable_cmd "$HOST_PEER" "$HOST_PEER_PORT")" || failed=1
  stack_step "ping $HOST_PEER fails" "if ping -c 1 -W 3 $HOST_PEER; then echo unexpected-reply; false; else true; fi" || failed=1
  stack_step "tailscale ping $HOST_PEER fails" "if timeout 20 tailscale ping -c 1 --timeout 5s $HOST_PEER; then echo unexpected-pong; false; else true; fi" || failed=1
  stack_step "no host-tailnet peers in tailscale status" "$(tmpl 'tailscale status --json | jq -e --argjson bad @BAD@ --arg sfx @SFX@ "[.Peer[]? | select(any(.TailscaleIPs[]?; . as \$i | any(\$bad[]; . == \$i)) or ((.DNSName // \"\") | endswith(\$sfx)))] | length == 0" >/dev/null || { tailscale status --json | jq -r ".Peer[]? | .DNSName"; false; }' \
    BAD "$(q "$HOST_IPS_JSON")" SFX "$(q ".$HOST_DNS_SUFFIX.")")" || failed=1
  # Every interface, not just conf/all: a per-interface setting can differ.
  stack_step "IPv6 is disabled on every interface" 'if grep -qx 0 /proc/sys/net/ipv6/conf/*/disable_ipv6; then grep -H . /proc/sys/net/ipv6/conf/*/disable_ipv6; false; fi' || failed=1
  return "$failed"
}

# shellcheck disable=SC2016 # these commands expand in the agent
a4_agent_internet() {
  stack_step "https://api.tailscale.com/ answers" 'code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 https://api.tailscale.com/); printf "http=%s\n" "$code"; [ -n "$code" ] && [ "$code" != 000 ]'
}

host_curl_nonce() {
  local got
  got=$(curl -fsS --max-time 15 "$@") || return 1
  [[ $got == "$NONCE" ]] || {
    echo "got=$got"
    return 1
  }
}

host_curl_status() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@")
  echo "http=$code"
  [[ $code =~ ^[23] ]]
}

a5_host_proxy_reaches_peer() {
  local failed=0 h px=127.0.0.1:$PROXY_PORT
  for h in "$TARGET_NAME" "$TARGET_IP"; do
    on_host "HTTP proxy to http://$h:8080/" host_curl_nonce -x "http://$px" "http://$h:8080/" || failed=1
    on_host "SOCKS5 proxy to http://$h:8080/" host_curl_nonce --socks5-hostname "$px" "http://$h:8080/" || failed=1
  done
  on_host "HTTP proxy to https://github.com" host_curl_status -x "http://$px" https://github.com || failed=1
  return "$failed"
}

a6_host_proxy_no_host_tailnet() {
  local failed=0
  host_peer_controls || failed=1
  on_host "SOCKS5 CONNECT to $HOST_PEER:$HOST_PEER_PORT is refused" expect_rc 1 probe socks "$HOST_PEER" "$HOST_PEER_PORT" "$PROXY_PORT" || failed=1
  on_host "HTTP CONNECT to $HOST_PEER:$HOST_PEER_PORT is refused" expect_rc 1 probe http "$HOST_PEER" "$HOST_PEER_PORT" "$PROXY_PORT" || failed=1
  return "$failed"
}

# shellcheck disable=SC2016 # these commands expand in the hooked host shell
a7_hook_exports_tailnet_proxy() {
  local failed=0
  hooked_step "ARGUS_TAILNET_PROXY is http://127.0.0.1:$PROXY_PORT" "$(tmpl 'printf "ARGUS_TAILNET_PROXY=%s\n" "${ARGUS_TAILNET_PROXY-(unset)}"; [ "${ARGUS_TAILNET_PROXY-}" = http://127.0.0.1:@P@ ]' P "$PROXY_PORT")" || failed=1
  hooked_step "no session-wide proxy variables" 'v=$(env | grep -iE "^(all|http|https)_proxy="); printf "%s\n" "$v"; [ -z "$v" ]' || failed=1
  hooked_step "curl -x \$ARGUS_TAILNET_PROXY http://$TARGET_NAME:8080/" "$(tmpl '[ -n "${ARGUS_TAILNET_PROXY-}" ] || { echo "ARGUS_TAILNET_PROXY is unset"; exit 1; }; r=$(curl -fsS --max-time 15 -x "$ARGUS_TAILNET_PROXY" http://@T@:8080/); printf "got=%s\n" "$r"; [ "$r" = @N@ ]' T "$TARGET_NAME" N "$NONCE")" || failed=1
  return "$failed"
}

node_id() {
  netguard_status | jq -er '.Self.ID // empty'
}

# agent_reaches_target: the agent reaches the target over the tailnet.
agent_reaches_target() {
  # shellcheck disable=SC2016 # expands in the agent
  in_stack "$(tmpl 'r=$(curl -fsS --max-time 10 http://@T@:8080/) && [ "$r" = @N@ ]' T "$TARGET_IP" N "$NONCE")"
}

# same_node_after LABEL ID: after a restart or recreate, netguard is healthy,
# still the node ID, and the agent reaches the target again.
same_node_after() {
  local id
  if ! wait_until "$DEADLINE" netguard_healthy; then
    CHECK_OUT+="$1: netguard never became healthy"$'\n'
    return 1
  fi
  id=$(node_id)
  if [[ $id != "$2" ]]; then
    CHECK_OUT+="$1: node ID is ${id:-unreadable}, was $2"$'\n'
    return 1
  fi
  if ! wait_until "$DEADLINE" agent_reaches_target; then
    CHECK_OUT+="$1: the agent does not reach the target: $OUT"$'\n'
    return 1
  fi
}

# shellcheck disable=SC2016 # these commands expand in the agent
a8_identity_and_restart() {
  local failed=0 id
  id=$(node_id) || {
    CHECK_OUT+="cannot read the node ID"$'\n'
    return 1
  }
  if ! compose restart -t 5 netguard >/dev/null 2>&1 || ! wait_until "$DEADLINE" netguard_healthy; then
    CHECK_OUT+="restarting netguard failed"$'\n'
    return 1
  fi
  # The agent still holds the old namespace: it must fail closed.
  stack_step "a stranded agent cannot reach the target" "$(tmpl 'if curl -fsS --max-time 5 http://@T@:8080/; then echo reached; false; else true; fi' T "$TARGET_IP")" || failed=1
  stack_step "a stranded agent has no internet" 'if curl -sS -o /dev/null --max-time 5 https://api.tailscale.com/; then echo reached; false; else true; fi' || failed=1
  if compose restart -t 5 agent >/dev/null 2>&1; then
    same_node_after "netguard restart, then agent restart" "$id" || failed=1
  else
    CHECK_OUT+="restarting the agent failed"$'\n'
    failed=1
  fi
  # A recreate strands the agent until the next up -d recreates it too,
  # which is what Argus runs before every exec.
  if compose -t 120 up -d --no-build --force-recreate netguard >/dev/null 2>&1 &&
    compose -t 120 up -d --no-build >/dev/null 2>&1; then
    same_node_after "netguard recreate" "$id" || failed=1
  else
    CHECK_OUT+="recreating netguard failed"$'\n'
    failed=1
  fi
  return "$failed"
}

# netguard_started: when netguard's container last started.
netguard_started() {
  local id
  id=$(compose ps -q netguard) && [[ -n $id ]] || return 1
  timeout "$STEP_TIMEOUT" docker inspect -f '{{.State.StartedAt}}' "$id"
}

# netguard_operator: tailscaled's operator, read as root in netguard.
netguard_operator() {
  local prefs
  prefs=$(compose exec -T netguard tailscale debug prefs 2>/dev/null) || return 1
  jq -r '.OperatorUser // empty' <<<"$prefs"
}

# a10_heals_after_logout: tailscale logout resets tailscaled's prefs, the
# operator included. netguard restores the operator without a restart, so the
# agent can log in again. Leaves the agent logged in, for teardown to log out.
a10_heals_after_logout() {
  local failed=0 started now op t0
  started=$(netguard_started) || {
    CHECK_OUT+="cannot read netguard's start time"$'\n'
    return 1
  }
  stack_step "tailscale logout from the agent" 'tailscale logout' || return 1
  t0=$SECONDS
  if wait_until "$DEADLINE" netguard_healthy; then
    log "netguard was healthy again $((SECONDS - t0)) s after the logout"
  else
    CHECK_OUT+="netguard did not become healthy within $DEADLINE s of the logout: $(compose exec -T netguard /opt/argus/bin/netguard.sh --check 2>&1)"$'\n'
    failed=1
  fi
  now=$(netguard_started)
  if [[ $now != "$started" ]]; then
    CHECK_OUT+="netguard restarted: it started at $started, and now at ${now:-an unreadable time}"$'\n'
    failed=1
  fi
  op=$(netguard_operator)
  if [[ $op != "$TS_OPERATOR" ]]; then
    CHECK_OUT+="tailscaled's operator is '$op', not '$TS_OPERATOR'"$'\n'
    failed=1
  fi
  if ! agent_up; then
    CHECK_OUT+="tailscale up from the agent after the logout:"$'\n'"$OUT"$'\n'
    failed=1
  elif ! wait_until "$DEADLINE" agent_logged_in; then
    CHECK_OUT+="the agent never came back up as $AGENT_HOST: $OUT"$'\n'
    failed=1
  fi
  return "$failed"
}

check_host_status() {
  local st
  st=$(timeout "$API_DEADLINE" tailscale status --json) || return 1
  jq -e --arg tn "$HOST_TAILNET" \
    '.BackendState == "Running" and .CurrentTailnet.Name == $tn and ([.Peer[]? | select((.HostName // "") | startswith("argus-e2e-"))] | length == 0)' \
    <<<"$st" >/dev/null && return 0
  jq -r '"state=\(.BackendState) tailnet=\(.CurrentTailnet.Name) e2e_peers=\([.Peer[]? | select((.HostName // "") | startswith("argus-e2e-")) | .HostName])"' <<<"$st"
  return 1
}

a9_host_unaffected() {
  on_host "host tailscale status" check_host_status
}

run_assertions() {
  assert A1 "the agent joined the other tailnet as the operator" a1_joined_as_operator
  assert A2 "the agent reaches a client-tailnet peer without NET_ADMIN" a2_agent_reaches_peer
  assert A3 "the agent cannot reach the host tailnet" a3_agent_no_host_tailnet
  assert A4 "the agent's internet egress works" a4_agent_internet
  assert A5 "the host proxy reaches the client tailnet and the internet" a5_host_proxy_reaches_peer
  assert A6 "the host proxy cannot reach the host tailnet" a6_host_proxy_no_host_tailnet
  assert A7 "the post_create hook exports ARGUS_TAILNET_PROXY and nothing session-wide" a7_hook_exports_tailnet_proxy
  assert A8 "the node keeps its identity across a netguard restart and recreate" a8_identity_and_restart
  assert A9 "the host is unaffected" a9_host_unaffected
  assert A10 "netguard heals after a logout, and the agent logs in again" a10_heals_after_logout
}

# td NAME CMD...: run one teardown step. Report a failure and carry on.
td() {
  local name=$1 out
  shift
  if ! out=$("$@" 2>&1); then
    TEARDOWN_ERRORS=$((TEARDOWN_ERRORS + 1))
    log "teardown: $name failed: $out"
  fi
}

# teardown: the EXIT trap. It acts only on what this run recorded as its own,
# and logs both nodes out, which removes them because the key is ephemeral.
# Every command it runs is bounded. Errors are reported but do not change the
# run's exit status.
teardown() {
  local rc=$?
  # Ignore further signals: every step below is bounded, and an interrupted
  # teardown would leave nodes on the tailnet.
  trap - EXIT
  trap '' INT TERM
  log "teardown"
  ((OWN_LOGIN)) && td "log out the agent's login" logout_owned_login
  ((TARGET_STARTED)) && td "log out and remove $TARGET_PROJECT" logout_target "$TARGET_PROJECT"
  ((STACK_WAS_UP)) || td "bring the stack down" timeout "$STEP_TIMEOUT" argus profile down "$PROFILE"
  ((TEARDOWN_ERRORS)) && log "teardown finished with $TEARDOWN_ERRORS error(s)"
  exit "$rc"
}

main() {
  parse_args "$@"
  init_run
  log "run $RUN_ID: profile $PROFILE, state root $STATE_DIR"
  preflight_checks
  trap teardown EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  recover
  start_target || die "the target node did not come up"
  start_agent || die "the agent did not join the test tailnet"
  run_assertions
  ((ASSERT_FAILED == 0))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
