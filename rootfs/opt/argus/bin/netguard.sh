#!/usr/bin/env bash
# Network guard for a dockerized Argus profile. The profile's agent shares this
# container's network namespace, so these routes apply to everything in it.
#
# Traffic from the container reaches the host through the Docker bridge, and
# the host routes tailnet addresses out of tailscale0. Without the guard,
# unproxied traffic reaches the host's tailnet peers as the host. The guard
# makes every tailnet prefix unreachable in the namespace and requires IPv6 to
# be disabled (service sysctl net.ipv6.conf.all.disable_ipv6=1). Userspace
# tailscaled has its own network stack, so the profile's own tailnet is
# unaffected. This is not a security boundary.
#
# Usage: netguard.sh          add the routes, then sleep
#        netguard.sh --check  healthcheck: exit 0 when the guard is in place
#
# NETGUARD_TAILNET_PREFIXES: IPv4 prefixes separated by commas or whitespace
# (default 100.64.0.0/10). Add any subnet routes the host accepts.
set -euo pipefail

raw=${NETGUARD_TAILNET_PREFIXES:-100.64.0.0/10}
read -r -a prefixes <<<"${raw//,/ }"
if ((${#prefixes[@]} == 0)); then
  echo "netguard: NETGUARD_TAILNET_PREFIXES is empty" >&2
  exit 1
fi

ipv6_disabled() {
  [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]]
}

check() {
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

if [[ ${1:-} == --check ]]; then
  check
  exit
fi

if ! ipv6_disabled; then
  echo "netguard: IPv6 is enabled; set sysctl net.ipv6.conf.all.disable_ipv6=1 on this service" >&2
  exit 1
fi
for p in "${prefixes[@]}"; do
  ip route add unreachable "$p"
done
check
echo "netguard: ${prefixes[*]} unreachable; IPv6 disabled"

trap 'exit 0' TERM INT
sleep infinity &
wait
