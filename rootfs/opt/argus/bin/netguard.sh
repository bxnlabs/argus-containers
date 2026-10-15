#!/usr/bin/env bash
# Network guard and tailnet daemon for a dockerized Argus profile. The
# profile's agent shares this container's network namespace, so the routes
# and the tailnet interface here apply to everything in it.
#
# Traffic from the container reaches the host through the Docker bridge, and
# the host routes its own tailnet's addresses out of its tailscale0. The guard
# makes every tailnet prefix unreachable in the namespace and requires IPv6 to
# be disabled (service sysctl net.ipv6.conf.all.disable_ipv6=1). tailscaled
# then runs here in TUN mode. Its per-peer routes live in table 52, which is
# looked up before the main table, so the profile's own tailnet peers stay
# reachable while every other tailnet address hits the guard. This is not a
# security boundary.
#
# tailscaled also serves an HTTP and SOCKS5 proxy on 0.0.0.0:1055, which the
# profile publishes on a loopback port for host-side sessions. It never runs
# `tailscale up`: joining a tailnet is a manual, one-time login.
#
# Usage: netguard.sh          add the guard routes, then run tailscaled
#        netguard.sh --check  healthcheck: exit 0 when the guard is in place,
#                             tailscaled answers on its socket, and the
#                             operator, if any, is in effect
#
# NETGUARD_TAILNET_PREFIXES: IPv4 prefixes separated by commas or whitespace
# (default 100.64.0.0/10). Add any subnet routes the host accepts.
# NETGUARD_TS_OPERATOR: a user name in this image that may control tailscaled
# without root (tailscale set --operator). Unset means only root may. When it
# is set but not in effect, the healthcheck fails, so the agent, which waits
# for a healthy netguard, never starts with read-only access.
set -euo pipefail

sock=/var/run/tailscale/tailscaled.sock

raw=${NETGUARD_TAILNET_PREFIXES:-100.64.0.0/10}
# read stops at the first newline, so fold a multi-line value onto one line.
raw=${raw//$'\n'/ }
read -r -a prefixes <<<"${raw//,/ }"
if ((${#prefixes[@]} == 0)); then
  echo "netguard: NETGUARD_TAILNET_PREFIXES is empty" >&2
  exit 1
fi

ipv6_disabled() {
  [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]]
}

guard_in_place() {
  local p
  if ! ipv6_disabled; then
    echo "netguard: IPv6 is not disabled" >&2
    return 1
  fi
  for p in "${prefixes[@]}"; do
    if [[ -z $(ip -4 route show type unreachable exact "$p") ]]; then
      echo "netguard: no unreachable route for $p" >&2
      return 1
    fi
  done
}

tailscaled_answers() {
  timeout 5 tailscale --socket="$sock" status --json >/dev/null 2>&1
}

# operator_in_effect: NETGUARD_TS_OPERATOR names a user here and is
# tailscaled's operator. tailscaled accepts any name, and resolves it to a uid
# only when a client connects, so both halves need checking.
operator_in_effect() {
  local want=$NETGUARD_TS_OPERATOR got
  if ! getent passwd "$want" >/dev/null; then
    echo "netguard: operator $want is not a user in this image" >&2
    return 1
  fi
  got=$(timeout 5 tailscale --socket="$sock" debug prefs 2>/dev/null | jq -r '.OperatorUser // empty')
  if [[ $got != "$want" ]]; then
    echo "netguard: tailscaled's operator is '$got', not $want" >&2
    return 1
  fi
}

if [[ ${1:-} == --check ]]; then
  guard_in_place
  if ! tailscaled_answers; then
    echo "netguard: tailscaled does not answer on $sock" >&2
    exit 1
  fi
  if [[ -n ${NETGUARD_TS_OPERATOR:-} ]]; then
    operator_in_effect
  fi
  exit
fi

if ! ipv6_disabled; then
  echo "netguard: IPv6 is enabled; set sysctl net.ipv6.conf.all.disable_ipv6=1 on this service" >&2
  exit 1
fi
# The namespace is new on every start, so the guard goes in every time, and
# before tailscaled can open any connection.
for p in "${prefixes[@]}"; do
  ip route replace unreachable "$p"
done
guard_in_place
echo "netguard: ${prefixes[*]} unreachable; IPv6 disabled"

tailscaled --tun=tailscale0 --statedir=/var/lib/tailscale --socket="$sock" \
  --socks5-server=0.0.0.0:1055 --outbound-http-proxy-listen=0.0.0.0:1055 &
tsd=$!
trap 'kill -TERM "$tsd" 2>/dev/null' TERM INT

# Retry while tailscaled starts. On failure netguard keeps running for
# inspection, and the healthcheck reports it.
if [[ -n ${NETGUARD_TS_OPERATOR:-} ]]; then
  deadline=$((SECONDS + 30))
  until tailscale --socket="$sock" set --operator="$NETGUARD_TS_OPERATOR" 2>/dev/null &&
    operator_in_effect 2>/dev/null; do
    if ((SECONDS >= deadline)) || ! kill -0 "$tsd" 2>/dev/null; then
      operator_in_effect || true
      echo "netguard: could not make $NETGUARD_TS_OPERATOR tailscaled's operator; the healthcheck fails until it is" >&2
      break
    fi
    sleep 0.5
  done
  if operator_in_effect 2>/dev/null; then
    echo "netguard: $NETGUARD_TS_OPERATOR may control tailscaled"
  fi
fi

# wait returns early when a trapped signal arrives; wait again for tailscaled
# to finish its own shutdown, and exit with its status.
rc=0
wait "$tsd" || rc=$?
if kill -0 "$tsd" 2>/dev/null; then
  rc=0
  wait "$tsd" || rc=$?
fi
exit "$rc"
