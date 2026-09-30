#!/usr/bin/env bash
# Tailnet-separation e2e for a dockerized Argus profile: the profile's
# container joins a test tailnet that is not the host's, and the two stay
# separate. Prerequisites and usage: README.md, "Tailnet-separation e2e".
#
# Usage: e2e/tailnet-separation.sh --profile NAME
#
# Exit status: 0 when every assertion passes, 1 when any fails, and 2 when the
# run aborts before its assertions.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=ghcr.io/bxnlabs/argus-containers/profile:main
E2E_TAG=tag:argus-e2e
DEADLINE=60     # bound for polls and agent_exec calls, in seconds
API_DEADLINE=15 # bound for a single Tailscale API or status call
STEP_TIMEOUT=30 # bound for each argus, docker and compose call
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

# uncovered_routes PREFIXES: read `ip -4 route show table 52` on stdin and
# print each destination routed out of tailscale0 that no prefix in PREFIXES
# (commas or whitespace between them) covers. `default` is 0.0.0.0/0.
uncovered_routes() {
  local line dst rest p covered raw=${1//$'\n'/ }
  local -a prefixes
  # Parse PREFIXES as netguard.sh does, newlines included.
  read -r -a prefixes <<<"${raw//,/ }"
  while IFS= read -r line; do
    [[ $line == *" dev tailscale0"* ]] || continue
    read -r dst rest <<<"$line"
    case $dst in unicast | local | broadcast | multicast) read -r dst <<<"$rest" ;; esac
    [[ $dst == default ]] && dst=0.0.0.0/0
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

# classify_login JSON TAILNET: classify a running profile's Tailscale login
# from `tailscale status --json`. Prints logged-out, e2e (a login an earlier
# e2e run left behind on TAILNET), or foreign (anything else, including
# unparseable input).
classify_login() {
  local out
  out=$(jq -r --arg tn "$2" '
    (.CurrentTailnet.Name // "") as $cur
    | (.Self.HostName // "") as $host
    | if ((.BackendState == "NeedsLogin" or .BackendState == "NoState") and $cur == "") then "logged-out"
      elif ($cur == $tn and ($host | startswith("argus-e2e-agent-"))) then "e2e"
      else "foreign" end' <<<"$1" 2>/dev/null)
  printf '%s\n' "${out:-foreign}"
}

# state_file_login FILE: whether a stopped profile's tailscaled.state holds a
# login. It does only when _current-profile names a profile that still exists
# in _profiles: logout deletes the profile but can leave the pointer behind.
# Fails when the file cannot be read or parsed.
state_file_login() {
  local file=$1 json cur profiles
  if [[ ! -e $file ]]; then
    echo logged-out
    return 0
  fi
  json=$(cat -- "$file") || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json" || return 1
  cur=$(jq -r '."_current-profile" // ""' <<<"$json" | base64 -d 2>/dev/null) || return 1
  if [[ -z $cur ]]; then
    echo logged-out
    return 0
  fi
  profiles=$(jq -r '."_profiles" // ""' <<<"$json" | base64 -d 2>/dev/null) || return 1
  if [[ -z $profiles ]]; then
    echo logged-out
    return 0
  fi
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$profiles" || return 1
  # tailscaled stores the profile's state key (its Key field, "profile-<ID>")
  # in _current-profile. A bare ID is accepted too.
  if jq -e --arg k "$cur" 'has($k) or any(.[]; .Key? == $k)' >/dev/null <<<"$profiles"; then
    echo logged-in
  else
    echo logged-out
  fi
}

# marker_result ID: read captured pane text on stdin. When the END marker for
# ID is there, print "rc=<n>" and then the lines between the BEGIN and END
# markers, and succeed; otherwise fail. Output that did not end in a newline
# shares its last line with the END marker, so the marker is found anywhere in
# a line.
marker_result() {
  awk -v id="$1" '
    { sub(/[ \t\r]+$/, "") }
    $0 == "ARGUS-E2E:BEGIN:" id { inside = 1; body = ""; next }
    inside && (p = index($0, "ARGUS-E2E:END:" id ":rc=")) > 0 {
      if (p > 1) body = body substr($0, 1, p - 1) "\n"
      rc = substr($0, p + length("ARGUS-E2E:END:" id ":rc="))
      if (rc ~ /^[0-9]+$/) { found = 1; result = body }
      inside = 0
      next
    }
    inside { body = body $0 "\n" }
    END { if (!found) exit 1; printf "rc=%s\n%s", rc, result }'
}

# strip_ctrl: drop control characters (other than tab and newline) from text
# read back from the session.
strip_ctrl() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

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

# is_run_name NAME: whether NAME is a session or repo name this script
# generates (argus-e2e- and an 8-hex-digit run ID). recover deletes only
# these, never other sessions that merely share the prefix.
is_run_name() { [[ $1 =~ ^argus-e2e-[0-9a-f]{8}$ ]]; }

parse_args() {
  PROFILE=
  while (($#)); do
    case $1 in
      --profile)
        PROFILE=${2:-}
        shift $(($# >= 2 ? 2 : 1))
        ;;
      --profile=*)
        PROFILE=${1#*=}
        shift
        ;;
      -h | --help)
        sed -n '2,10p' "$0"
        exit 0
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ -n $PROFILE ]] || die "usage: $0 --profile NAME"
  [[ $PROFILE =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $PROFILE"
}

init_run() {
  ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) || die "bash 5.1 or later is required"
  STATE_DIR=$(resolve_state_dir) || die "cannot resolve the Argus state root"
  PROFILE_DIR=$STATE_DIR/profiles/$PROFILE
  CRED_FILE=$HOME/.config/argus-e2e/$PROFILE.env
  RUN_ID=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  export RUN_ID NONCE
  SESSION=argus-e2e-$RUN_ID
  TARGET=argus-e2e-target-$RUN_ID
  AGENT_HOST=argus-e2e-agent-$RUN_ID
  REPO_DIR=$STATE_DIR/tmp/argus-e2e-$RUN_ID
  AGENT_KEY=$PROFILE_DIR/.tailscale/e2e-authkey
  # Teardown acts only on what these record as this run's.
  SESSION_CREATED=0 TARGET_STARTED=0 OWN_LOGIN=0 REPO_CREATED=0 PROBE_PID="" KEY_DIR=""
  STACK_WAS_UP=0 ABANDONED_LOGIN=0 TOKEN="" PEER_IP="" TEARDOWN_ERRORS=0
}

# compose ARGS...: docker compose against the profile's stack, with the four
# variables Argus passes, bounded by STEP_TIMEOUT.
compose() {
  ARGUS_HOST_HOME=$HOME ARGUS_STATE_DIR=$STATE_DIR ARGUS_UID=$(id -u) ARGUS_GID=$(id -g) \
    timeout "$STEP_TIMEOUT" docker compose -p "argus-$PROFILE" -f "$COMPOSE_FILE" "$@"
}

# guard_prefixes: the profile's NETGUARD_TAILNET_PREFIXES (netguard.sh's
# default when unset). Fails when the profile has no netguard service.
guard_prefixes() {
  compose config --format json 2>/dev/null | jq -er --arg d "$DEFAULT_GUARD_PREFIXES" '
    if .services.netguard == null then error("no netguard service")
    else .services.netguard.environment.NETGUARD_TAILNET_PREFIXES // $d end'
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

# ts_api METHOD PATH [JSON_BODY]: call the Tailscale API. The token goes in
# through curl's stdin config, never argv.
ts_api() {
  local -a args=(-fsS --max-time "$API_DEADLINE" -X "$1" -K -)
  [[ -n ${3:-} ]] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl "${args[@]}" "https://api.tailscale.com/api/v2$2"
}

get_token() {
  local resp
  resp=$(printf 'client_id=%s&client_secret=%s' "$TS_E2E_OAUTH_CLIENT_ID" "$TS_E2E_OAUTH_CLIENT_SECRET" |
    curl -fsS --max-time "$API_DEADLINE" --data-binary @- https://api.tailscale.com/api/v2/oauth/token) || return 1
  TOKEN=$(jq -r '.access_token // empty' <<<"$resp")
  [[ -n $TOKEN ]]
}

# mint_key FILE: mint a single-use, ephemeral, preauthorized auth key tagged
# E2E_TAG that expires in 600 seconds, and write it to FILE with mode 0600.
mint_key() {
  local body resp key
  body=$(jq -nc --arg tag "$E2E_TAG" \
    '{capabilities: {devices: {create: {reusable: false, ephemeral: true, preauthorized: true, tags: [$tag]}}},
      expirySeconds: 600, description: "argus-e2e"}')
  resp=$(ts_api POST /tailnet/-/keys "$body") || return 1
  key=$(jq -r '.key // empty' <<<"$resp")
  [[ -n $key ]] || return 1
  (umask 077 && printf '%s' "$key" >"$1")
}

delete_e2e_devices() {
  local resp id rc=0
  resp=$(ts_api GET /tailnet/-/devices) || return 1
  for id in $(jq -r '.devices[] | select(.hostname | startswith("argus-e2e-")) | .nodeId // .id' <<<"$resp"); do
    ts_api DELETE "/device/$id" >/dev/null || rc=1
  done
  return "$rc"
}

# logout_owned_login: end the run's login through compose exec, not the
# session. Kill any `tailscale up` still running, restart tailscaled so an
# enrollment pending inside the daemon is abandoned rather than completing
# later, then log out. (logout alone returns early when no node key exists
# yet, without cancelling a pending login.)
logout_owned_login() {
  # shellcheck disable=SC2016 # the script runs in the container, not here.
  compose exec -T agent bash -c '
    pkill -f "[t]ailscale up --auth-key" || true
    supervisorctl -c /etc/supervisor/supervisord.conf restart tailscaled >/dev/null
    for _ in $(seq 20); do tailscale status --json >/dev/null 2>&1 && break; sleep 1; done
    tailscale logout >/dev/null 2>&1 || true
    state=$(tailscale status --json | jq -r .BackendState)
    [ "$state" = NeedsLogin ] || [ "$state" = NoState ] || { echo "tailscale is still $state"; exit 1; }'
}

preflight_checks() {
  local c st uncovered services
  for c in argus docker curl jq timeout tailscale ip python3 git od; do
    command -v "$c" >/dev/null || die "missing host command: $c"
  done
  [[ -f $CRED_FILE ]] || die "missing $CRED_FILE (README: Tailnet-separation e2e)"
  [[ $(stat -c %a -- "$CRED_FILE") == 600 ]] || die "$CRED_FILE must have mode 0600"
  # shellcheck source=/dev/null
  . "$CRED_FILE"
  [[ -n ${TS_E2E_OAUTH_CLIENT_ID:-} && -n ${TS_E2E_OAUTH_CLIENT_SECRET:-} && -n ${TS_E2E_TAILNET:-} ]] ||
    die "$CRED_FILE must set TS_E2E_OAUTH_CLIENT_ID, TS_E2E_OAUTH_CLIENT_SECRET and TS_E2E_TAILNET"

  timeout "$STEP_TIMEOUT" argus session ls --json >/dev/null 2>&1 || die "the Argus node does not answer"
  [[ $(timeout "$STEP_TIMEOUT" argus profile ls 2>/dev/null | awk -v p="$PROFILE" '$1 == p { print $2 }') == docker ]] ||
    die "$PROFILE is not a dockerized Argus profile"
  COMPOSE_FILE=$(find_compose_file "$PROFILE_DIR") || die "no compose file in $PROFILE_DIR"

  HOST_STATUS=$(timeout "$API_DEADLINE" tailscale status --json 2>/dev/null) || die "host tailscale status failed"
  [[ $(jq -r .BackendState <<<"$HOST_STATUS") == Running ]] || die "the host is not connected to its tailnet"
  HOST_TAILNET=$(jq -r '.CurrentTailnet.Name // empty' <<<"$HOST_STATUS")
  [[ -n $HOST_TAILNET ]] || die "cannot read the host's tailnet name"
  [[ $HOST_TAILNET != "$TS_E2E_TAILNET" ]] || die "the host is on the test tailnet $TS_E2E_TAILNET"
  HOST_TS_IP=$(jq -r '[.Self.TailscaleIPs[]? | select(test("^[0-9.]+$"))][0] // empty' <<<"$HOST_STATUS")
  HOST_DNS=$(jq -r '(.Self.DNSName // "") | rtrimstr(".")' <<<"$HOST_STATUS")
  HOST_DNS_SUFFIX=$(jq -r '.CurrentTailnet.MagicDNSSuffix // .MagicDNSSuffix // empty' <<<"$HOST_STATUS")
  HOST_IPS_JSON=$(jq -c '[.Self.TailscaleIPs[]?, .Peer[]?.TailscaleIPs[]?]' <<<"$HOST_STATUS")
  [[ -n $HOST_TS_IP && -n $HOST_DNS && -n $HOST_DNS_SUFFIX ]] || die "cannot read the host's tailnet IP or MagicDNS name"
  log "host tailnet $HOST_TAILNET: $HOST_DNS ($HOST_TS_IP)"

  GUARD_PREFIXES=$(guard_prefixes) || die "cannot read NETGUARD_TAILNET_PREFIXES from $COMPOSE_FILE (is there a netguard service?)"
  uncovered=$(ip -4 route show table 52 | uncovered_routes "$GUARD_PREFIXES") ||
    die "cannot inspect the host's Tailscale routes (ip route table 52)"
  [[ -z $uncovered ]] ||
    die "host Tailscale routes not covered by NETGUARD_TAILNET_PREFIXES=$GUARD_PREFIXES: $(tr '\n' ' ' <<<"$uncovered")"

  services=$(compose ps --status running --services) || die "cannot read the profile's stack state"
  if grep -qx agent <<<"$services"; then
    STACK_WAS_UP=1
    st=$(compose exec -T agent tailscale status --json 2>/dev/null)
    case $(classify_login "$st" "$TS_E2E_TAILNET") in
      logged-out) ;;
      e2e) ABANDONED_LOGIN=1 ;;
      *) die "the profile is logged in to a tailnet this e2e does not own; log it out first (tailscale logout)" ;;
    esac
  else
    case $(state_file_login "$PROFILE_DIR/.tailscale/tailscaled.state") in
      logged-out) ;;
      logged-in) die "the stopped profile has a saved Tailscale login; start it and run tailscale logout first" ;;
      *) die "cannot read $PROFILE_DIR/.tailscale/tailscaled.state" ;;
    esac
  fi
  log "stack was $( ((STACK_WAS_UP)) && echo up || echo down ) before the test"
}

# recover: clean up after earlier crashed runs.
recover() {
  local sessions id name dir names n
  if ((ABANDONED_LOGIN)); then
    log "logging out a login left by an earlier e2e run"
    OWN_LOGIN=1
    logout_owned_login || die "could not log out the abandoned e2e login"
  fi
  sessions=$(timeout "$STEP_TIMEOUT" argus session ls --json | jq -r '.sessions[] | [.id, .name] | @tsv') ||
    die "listing Argus sessions failed"
  while IFS=$'\t' read -r id name; do
    is_run_name "$name" || continue
    log "deleting leftover session $name ($id)"
    timeout "$STEP_TIMEOUT" argus session rm "$id" --force --delete-branch >/dev/null 2>&1 ||
      timeout "$STEP_TIMEOUT" argus session rm "$id" --force >/dev/null ||
      die "could not delete leftover session $id"
  done <<<"$sessions"
  for dir in "$STATE_DIR"/tmp/argus-e2e-*; do
    if is_run_name "${dir##*/}"; then rm -rf -- "$dir"; fi
  done
  names=$(timeout "$STEP_TIMEOUT" docker ps -a --filter 'name=^argus-e2e-target-' --format '{{.Names}}') ||
    die "listing containers failed"
  for n in $names; do
    log "removing leftover container $n"
    timeout "$STEP_TIMEOUT" docker rm -f "$n" >/dev/null || die "could not remove $n"
  done
  delete_e2e_devices || die "sweeping leftover argus-e2e devices failed"
}

# start_probe_listener: listen on the host's tailnet IP and answer every
# connection with an HTTP response carrying NONCE, so a probe that reaches it
# is recognizable whatever the path.
start_probe_listener() {
  local portfile
  portfile=$(mktemp) || return 1
  timeout 900 python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
body = sys.argv[2].encode()
resp = b"HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body)
while True:
    c = s.accept()[0]
    try:
        c.settimeout(5)
        c.recv(4096)
        c.sendall(resp)
    except OSError:
        pass
    c.close()' "$HOST_TS_IP" "$NONCE" >"$portfile" 2>/dev/null &
  PROBE_PID=$!
  wait_until 10 test -s "$portfile"
  PROBE_PORT=$(head -n1 "$portfile")
  rm -f -- "$portfile"
  [[ -n $PROBE_PORT ]]
}

# choose_probe: start the probe listener on the host's tailnet IP, and pick
# one host-tailnet peer that answers tailscale ping, if any.
choose_probe() {
  local ip
  start_probe_listener || die "starting the probe listener on $HOST_TS_IP failed"
  log "A4 probe: $HOST_TS_IP:$PROBE_PORT"
  for ip in $(jq -r '.Peer[]? | select(.Online) | .TailscaleIPs[]? | select(test("^[0-9.]+$"))' <<<"$HOST_STATUS" | head -n 3); do
    if timeout 20 tailscale ping --until-direct=false -c 1 --timeout 5s "$ip" >/dev/null 2>&1; then
      PEER_IP=$ip
      break
    fi
  done
  log "A4 peer: ${PEER_IP:-none answering}"
}

target_ready() {
  [[ $(timeout "$API_DEADLINE" docker exec "$TARGET" tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') == Running ]] &&
    [[ $(timeout "$API_DEADLINE" docker exec "$TARGET" curl -fsS --max-time 5 http://localhost:8080/ 2>/dev/null) == "$NONCE" ]]
}

start_target() {
  log "starting target $TARGET"
  KEY_DIR=$(mktemp -d) || return 1
  mint_key "$KEY_DIR/authkey" || { log "minting the target's auth key failed"; return 1; }
  TARGET_STARTED=1
  timeout 600 docker run -d --name "$TARGET" \
    -v "$REPO_ROOT/e2e/target:/e2e:ro" -v "$KEY_DIR:/run/e2e:ro" \
    -e NONCE -e RUN_ID --entrypoint /e2e/run.sh "$IMAGE" >/dev/null ||
    { log "docker run failed"; return 1; }
  if ! wait_until "$DEADLINE" target_ready; then
    log "the target never reported Running and served the nonce; its last log lines:"
    timeout "$API_DEADLINE" docker logs --tail 30 "$TARGET" >&2
    return 1
  fi
  rm -rf -- "$KEY_DIR"
  KEY_DIR=""
}

# agent_exec [-t SECONDS] CMD: type CMD into the e2e session's shell and wait
# for it to finish. Sets AGENT_OUT to what CMD printed and returns CMD's exit
# status. Returns 124 when the END marker does not appear in time (AGENT_OUT
# then holds the tail of the pane) and 125 when sending fails. Every "run
# inside the agent" call goes through here, so a future Argus-free variant can
# swap in `docker compose exec`. Call it directly, not inside $(...): the
# command counter must survive between calls.
AGENT_SEQ=0
AGENT_OUT=""
agent_exec() {
  local deadline=$DEADLINE cmd id line pane="" result rc end
  if [[ $1 == -t ]]; then
    deadline=$2
    shift 2
  fi
  cmd=$1
  AGENT_SEQ=$((AGENT_SEQ + 1))
  id=$RUN_ID-$AGENT_SEQ-$SRANDOM
  # The markers are assembled by printf in the session, so the echoed command
  # line never contains the literal ARGUS-E2E:END:<id> text.
  line="printf '%s:%s:%s\n' ARGUS-E2E BEGIN $id; $cmd; printf '%s:%s:%s:rc=%d\n' ARGUS-E2E END $id \$?"
  AGENT_OUT=""
  if ! timeout "$STEP_TIMEOUT" argus session send "$SESSION" "$line" --enter >/dev/null 2>&1; then
    AGENT_OUT="argus session send failed"
    return 125
  fi
  end=$((SECONDS + deadline))
  while ((SECONDS < end)); do
    pane=$(timeout "$STEP_TIMEOUT" argus session peek "$SESSION" --all 2>/dev/null | strip_ctrl)
    if result=$(marker_result "$id" <<<"$pane"); then
      rc=${result%%$'\n'*}
      AGENT_OUT=${result#*$'\n'}
      return "${rc#rc=}"
    fi
    sleep 1
  done
  AGENT_OUT="timed out after ${deadline}s; last pane lines:"$'\n'$(tail -n 20 <<<"$pane")
  return 124
}

# wait_shell_ready: type a harmless marker command every 5 seconds until one
# shows up in the pane, which proves the shell is reading input.
wait_shell_ready() {
  local n=0 end=$((SECONDS + DEADLINE)) i
  while ((SECONDS < end)); do
    n=$((n + 1))
    timeout "$STEP_TIMEOUT" argus session send "$SESSION" "printf '%s:%s\n' ARGUS-E2E READY-$RUN_ID-$n" --enter >/dev/null 2>&1
    for i in 1 2 3 4 5; do
      sleep 1
      if timeout "$STEP_TIMEOUT" argus session peek "$SESSION" --all 2>/dev/null | strip_ctrl |
        grep -q "^ARGUS-E2E:READY-$RUN_ID-"; then
        return 0
      fi
    done
  done
  return 1
}

daemon_needs_login() {
  agent_exec -t "$API_DEADLINE" 'tailscale status --json | jq -e ".BackendState == \"NeedsLogin\"" >/dev/null'
}

agent_logged_in() {
  # shellcheck disable=SC2016 # expands in the session's shell
  agent_exec -t "$API_DEADLINE" "$(tmpl 'tailscale status --json | jq -e --arg h @H@ ".Self.HostName == \$h and .BackendState == \"Running\"" >/dev/null' H "$AGENT_HOST")"
}

start_agent() {
  local rc
  log "creating session $SESSION in profile $PROFILE"
  REPO_CREATED=1
  # shellcheck disable=SC2015 # the fallback runs when any step fails, as intended
  mkdir -p "$REPO_DIR" &&
    git -C "$REPO_DIR" init -q -b main &&
    git -C "$REPO_DIR" -c user.name=argus-e2e -c user.email=argus-e2e@localhost commit -q --allow-empty -m "argus e2e $RUN_ID" ||
    { log "creating the throwaway repo failed"; return 1; }
  SESSION_CREATED=1
  # A shell session brings the stack up lazily through the real Argus path.
  timeout 600 argus session new "$SESSION" --provider shell --profile "$PROFILE" --src "$REPO_DIR" --branch "$SESSION" >/dev/null ||
    { log "argus session new failed"; return 1; }

  wait_shell_ready || { log "the session shell never answered"; return 1; }
  # The image's SHELL makes the session a zsh login shell.
  # shellcheck disable=SC2016 # expands in the session's shell
  agent_exec 'test -n "$ZSH_VERSION"' || { log "the session shell is not zsh: $AGENT_OUT"; return 1; }
  # oh-my-zsh's url-quote-magic (run on pasted text by bracketed-paste-magic)
  # escapes characters that follow a URL, so `curl http://h/; rc=$?` reaches
  # the shell as `curl http://h/\; rc=$?`. Restore zsh's builtin widgets so
  # every command runs exactly as sent.
  agent_exec 'zle -A .self-insert self-insert && zle -A .bracketed-paste bracketed-paste' ||
    { log "restoring zsh's builtin line-editor widgets failed: $AGENT_OUT"; return 1; }
  wait_until "$DEADLINE" daemon_needs_login ||
    { log "tailscaled in the session never reported NeedsLogin: $AGENT_OUT"; return 1; }

  mint_key "$AGENT_KEY" || { log "minting the agent's auth key failed"; return 1; }
  # From here on, any login in the profile is this run's: preflight saw it
  # logged out, or recovered the abandoned e2e login.
  OWN_LOGIN=1
  log "enrolling $AGENT_HOST"
  agent_exec "timeout -k 5 45 tailscale up --auth-key=file:/var/lib/tailscale/e2e-authkey --hostname=$AGENT_HOST"
  rc=$?
  rm -f -- "$AGENT_KEY"
  ((rc == 0)) || { log "tailscale up failed (rc=$rc): $AGENT_OUT"; return 1; }
  wait_until "$DEADLINE" agent_logged_in || { log "the agent never came up as $AGENT_HOST: $AGENT_OUT"; return 1; }
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

# in_agent LABEL CMD: one step of an assertion, run in the session. On failure
# its label, status and output go into CHECK_OUT.
in_agent() {
  local rc
  agent_exec "$2"
  rc=$?
  if ((rc != 0)); then
    CHECK_OUT+="$1 (rc=$rc):"$'\n'"$AGENT_OUT"$'\n'
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

# shellcheck disable=SC2016 # these commands expand in the session's shell
a1_joined_test_tailnet() {
  in_agent "tailnet name" "$(tmpl 'n=$(tailscale status --json | jq -r ".CurrentTailnet.Name // empty"); printf "tailnet=%s\n" "$n"; [ "$n" = @WANT@ ] && [ "$n" != @HOST@ ]' \
    WANT "$(q "$TS_E2E_TAILNET")" HOST "$(q "$HOST_TAILNET")")"
}

a2_peer_ping() {
  # --until-direct defaults to true, which fails a working DERP-relayed path.
  in_agent "tailscale ping $TARGET" "timeout 40 tailscale ping --until-direct=false -c 3 --timeout 10s $TARGET"
}

# shellcheck disable=SC2016 # these commands expand in the session's shell
a3_proxy_http() {
  in_agent "curl http://$TARGET:8080/" "$(tmpl 'r=$(curl -fsS --max-time 15 http://@T@:8080/); printf "got=%s\n" "$r"; [ "$r" = @N@ ]' T "$TARGET" N "$NONCE")"
}

host_gets_nonce() {
  [[ $(curl -sS --noproxy '*' --max-time 5 "http://$HOST_TS_IP:$PROBE_PORT/") == "$NONCE" ]]
}

# shellcheck disable=SC2016 # these commands expand in the session's shell
a4_no_host_tailnet() {
  local failed=0
  local py='import errno, socket, sys; s = socket.socket(); s.settimeout(5); r = s.connect_ex((sys.argv[1], int(sys.argv[2]))); print(errno.errorcode.get(r, r)); sys.exit(0 if r in (errno.EHOSTUNREACH, errno.ENETUNREACH) else 1)'

  # Positive controls from the host, immediately before: the targets are there.
  on_host "control: host gets the nonce from $HOST_TS_IP:$PROBE_PORT" host_gets_nonce || failed=1
  if [[ -n $PEER_IP ]]; then
    on_host "control: host pings $PEER_IP" timeout 20 tailscale ping --until-direct=false -c 1 --timeout 5s "$PEER_IP" || failed=1
  fi

  # Through Tailscale.
  in_agent "no host-tailnet peers in tailscale status" "$(tmpl 'tailscale status --json | jq -e --argjson bad @BAD@ --arg sfx @SFX@ "[.Peer[]? | select(any(.TailscaleIPs[]?; . as \$i | any(\$bad[]; . == \$i)) or ((.DNSName // \"\") | endswith(\$sfx)))] | length == 0" >/dev/null || { tailscale status --json | jq -r ".Peer[]? | .DNSName"; false; }' \
    BAD "$(q "$HOST_IPS_JSON")" SFX "$(q ".$HOST_DNS_SUFFIX.")")" || failed=1
  in_agent "tailscale ping $HOST_TS_IP fails" "if timeout 20 tailscale ping -c 1 --timeout 5s $HOST_TS_IP; then echo unexpected-pong; false; else true; fi" || failed=1
  in_agent "curl http://$HOST_DNS:$PROBE_PORT/ does not reach the host" "$(tmpl 'r=$(curl -sS --max-time 5 http://@D@:@P@/); printf "rc=%s got=%s\n" "$?" "$r"; [ "$r" != @N@ ]' D "$HOST_DNS" P "$PROBE_PORT" N "$NONCE")" || failed=1

  # Direct path: no proxy, the kernel route must refuse with EHOSTUNREACH or
  # ENETUNREACH (not a timeout or a refusal).
  in_agent "direct connect to $HOST_TS_IP:$PROBE_PORT is unreachable" "python3 -c $(q "$py") $HOST_TS_IP $PROBE_PORT" || failed=1
  if [[ -n $PEER_IP ]]; then
    in_agent "direct connect to $PEER_IP:$PROBE_PORT is unreachable" "python3 -c $(q "$py") $PEER_IP $PROBE_PORT" || failed=1
  fi
  # Every interface, not just conf/all: a per-interface setting can differ.
  in_agent "IPv6 is disabled on every interface" 'if grep -qx 0 /proc/sys/net/ipv6/conf/*/disable_ipv6; then grep -H . /proc/sys/net/ipv6/conf/*/disable_ipv6; false; fi' || failed=1
  in_agent "ip route get $HOST_TS_IP is unreachable" "$(tmpl 'out=$(ip route get @IP@ 2>&1); rc=$?; printf "%s\n" "$out"; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -qiE "unreachable|no route to host"' IP "$HOST_TS_IP")" || failed=1
  return "$failed"
}

# shellcheck disable=SC2016 # these commands expand in the session's shell
a5_internet_egress() {
  in_agent "https://api.tailscale.com/ answers" 'code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 https://api.tailscale.com/); printf "http=%s\n" "$code"; [ -n "$code" ] && [ "$code" != 000 ]'
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

a6_host_unaffected() {
  on_host "host tailscale status" check_host_status
}

# shellcheck disable=SC2016 # these commands expand in the session's shell
a7_env_from_hook() {
  # /proc/$$/environ is the environment Argus started the login shell with,
  # after the hook and before .zshrc.
  in_agent "session shell's initial environment" 'e=$(tr "\0" "\n" < /proc/$$/environ); n=$(printf "%s\n" "$e" | grep -cixE "(all|http|https)_proxy=http://localhost:1055"); printf "proxy_vars=%s\n" "$n"; [ "$n" -eq 6 ] && printf "%s\n" "$e" | grep -qx "ARGUS_E2E_POST_CREATE=in-container-sentinel"' || return 1
  in_agent "curl from zsh -f" "$(tmpl 'r=$(zsh -f -c "curl -fsS --max-time 15 http://@T@:8080/"); printf "got=%s\n" "$r"; [ "$r" = @N@ ]' T "$TARGET" N "$NONCE")"
}

run_assertions() {
  assert A1 "joined the other tailnet" a1_joined_test_tailnet
  assert A2 "peer connectivity" a2_peer_ping
  assert A3 "proxy, MagicDNS and a real service" a3_proxy_http
  assert A4 "the container cannot reach the host tailnet by any path" a4_no_host_tailnet
  assert A5 "internet egress still works through the proxy" a5_internet_egress
  assert A6 "the host is unaffected" a6_host_unaffected
  assert A7 "the proxy comes from the post_create hook, not .zshrc" a7_env_from_hook
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

# teardown: the EXIT trap. It acts only on what this run recorded as its own.
# Every command it runs is bounded (STEP_TIMEOUT or API_DEADLINE). Errors are
# reported but do not change the run's exit status.
teardown() {
  local rc=$?
  trap - EXIT INT TERM
  log "teardown"
  ((SESSION_CREATED)) && td "delete session $SESSION" timeout "$STEP_TIMEOUT" argus session rm "$SESSION" --force --delete-branch
  ((OWN_LOGIN)) && td "log out the e2e login" logout_owned_login
  # Remove the target before listing devices, so an enrollment still pending
  # cannot complete after the sweep.
  ((TARGET_STARTED)) && td "remove $TARGET" timeout "$STEP_TIMEOUT" docker rm -f "$TARGET"
  [[ -n $TOKEN ]] && td "delete argus-e2e devices" delete_e2e_devices
  [[ -n $PROBE_PID ]] && td "stop the probe listener" kill "$PROBE_PID"
  ((REPO_CREATED)) && td "delete $REPO_DIR" rm -rf -- "$REPO_DIR"
  [[ -n $KEY_DIR ]] && td "delete the target key" rm -rf -- "$KEY_DIR"
  td "delete the agent key" rm -f -- "$AGENT_KEY"
  ((STACK_WAS_UP)) || td "bring the stack down" timeout "$STEP_TIMEOUT" argus profile down "$PROFILE"
  ((TEARDOWN_ERRORS)) && log "teardown finished with $TEARDOWN_ERRORS error(s)"
  exit "$rc"
}

main() {
  parse_args "$@"
  init_run
  log "run $RUN_ID: profile $PROFILE, state root $STATE_DIR"
  preflight_checks
  get_token || die "exchanging the OAuth client for an API token failed"
  trap teardown EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  recover
  choose_probe
  start_target || die "the target node did not come up"
  start_agent || die "the agent did not join the test tailnet"
  run_assertions
  ((ASSERT_FAILED == 0))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
