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

# shellcheck disable=SC2034 # used by later phases
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034 # used by later phases
IMAGE=ghcr.io/bxnlabs/argus-containers/profile:main
# shellcheck disable=SC2034 # used by later phases
E2E_TAG=tag:argus-e2e
# shellcheck disable=SC2034 # used by later phases
DEADLINE=60     # bound for polls and agent_exec calls, in seconds
# shellcheck disable=SC2034 # used by later phases
API_DEADLINE=15 # bound for a single Tailscale API or status call
# shellcheck disable=SC2034 # used by later phases
STEP_TIMEOUT=30 # bound for each argus, docker and compose call
# shellcheck disable=SC2034 # used by later phases
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
  if jq -e --arg id "$cur" 'has($id)' >/dev/null <<<"$profiles"; then
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

main() {
  die "not implemented yet"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
