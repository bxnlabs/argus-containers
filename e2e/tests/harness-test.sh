#!/usr/bin/env bash
# Unit tests for the pure helpers in e2e/tailnet-separation.sh. They need no
# Argus, Docker or network.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=e2e/tailnet-separation.sh
. "$here/../tailnet-separation.sh"

fails=0
ok() {
  if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fails=$((fails + 1)); fi
}
nok() {
  if "$@"; then echo "FAIL (expected failure) $*"; fails=$((fails + 1)); else echo "ok   ! $*"; fi
}
eq() {
  if [[ $3 == "$2" ]]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# resolve_state_dir follows Argus's shared.StateDir.
eq "state dir default" "$HOME/.argus" "$(unset ARGUS_HOME; resolve_state_dir)"
# shellcheck disable=SC2088 # a literal ~ is the input under test
eq "state dir ~/x" "$HOME/x" "$(ARGUS_HOME='~/x' resolve_state_dir)"
eq "state dir ~" "$HOME" "$(ARGUS_HOME='~' resolve_state_dir)"
eq "state dir cleaned" "/a/c" "$(ARGUS_HOME=/a//b/../c/ resolve_state_dir)"
nok env ARGUS_HOME=rel/path bash -c ". '$here/../tailnet-separation.sh'; resolve_state_dir 2>/dev/null"

# find_compose_file uses Compose's resolution order.
tmp=$(mktemp -d)
nok find_compose_file "$tmp"
touch "$tmp/docker-compose.yml" "$tmp/compose.yml"
eq "compose order" "$tmp/compose.yml" "$(find_compose_file "$tmp")"
rm -rf "$tmp"

# is_target_project matches only generated target projects.
ok is_target_project e2e-tailnet-target-79a901f3
nok is_target_project e2e-tailnet-target-79a901f
nok is_target_project argus-e2e-target-79a901f3
nok is_target_project xe2e-tailnet-target-79a901f3
nok is_target_project e2e-tailnet-target-79a901f3x

# cidr_covers
ok cidr_covers 100.64.0.0/10 100.65.124.11
ok cidr_covers 100.64.0.0/10 100.100.100.100
ok cidr_covers 100.64.0.0/10 100.127.255.255/32
ok cidr_covers 0.0.0.0/0 1.2.3.4
nok cidr_covers 100.64.0.0/10 100.128.0.0
nok cidr_covers 100.64.0.0/10 100.0.0.0/8
nok cidr_covers 100.64.0.0/10 0.0.0.0/0
nok cidr_covers 100.64.0.0/10 192.168.1.0/24
nok cidr_covers 100.64.0.0/10 999.1.1.1

# uncovered_routes reads one destination per line.
routes=$'192.168.1.0/24\n100.100.100.100\n0.0.0.0/0'
eq "uncovered: subnet and exit node" $'192.168.1.0/24\n0.0.0.0/0' "$(uncovered_routes 100.64.0.0/10 <<<"$routes")"
eq "uncovered: comma list covers subnet" "0.0.0.0/0" "$(uncovered_routes '100.64.0.0/10, 192.168.0.0/16' <<<"$routes")"
eq "uncovered: multi-line list covers subnet" "0.0.0.0/0" "$(uncovered_routes $'100.64.0.0/10,\n192.168.0.0/16' <<<"$routes")"
eq "uncovered: /32 subnet route" "" "$(uncovered_routes '100.64.0.0/10,10.254.10.1/32' <<<10.254.10.1/32)"
eq "uncovered: empty" "" "$(uncovered_routes 100.64.0.0/10 </dev/null)"

# host_routes: subnet routes the host accepts, and an exit node.
st='{"Peer":{"a":{"PrimaryRoutes":["10.254.10.1/32","fd00::/64"]},"b":{}}}'
eq "host routes: subnet, IPv6 dropped" "10.254.10.1/32" "$(host_routes "$st" true)"
eq "host routes: not accepted" "" "$(host_routes "$st" false)"
eq "host routes: exit node" $'10.254.10.1/32\n0.0.0.0/0' "$(host_routes '{"ExitNodeStatus":{"ID":"x"},"Peer":{"a":{"PrimaryRoutes":["10.254.10.1/32"]}}}' true)"
eq "host routes: none" "" "$(host_routes '{"Peer":{}}' true)"

# classify_login: the second argument is the host's tailnet.
eq "login: logged out" logged-out "$(classify_login '{"BackendState":"NeedsLogin","Self":{"HostName":"prime"}}' host.example)"
eq "login: abandoned e2e" e2e "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"e2e.example"},"Self":{"HostName":"argus-e2e-agent-1a2b3c4d"}}' host.example)"
eq "login: e2e name on the host's tailnet" foreign "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"host.example"},"Self":{"HostName":"argus-e2e-agent-1a2b3c4d"}}' host.example)"
eq "login: e2e-like name" foreign "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"e2e.example"},"Self":{"HostName":"argus-e2e-agent-1a2b3c4d-2"}}' host.example)"
eq "login: real login" foreign "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"e2e.example"},"Self":{"HostName":"prime"}}' host.example)"
eq "login: stopped but logged in" foreign "$(classify_login '{"BackendState":"Stopped","CurrentTailnet":{"Name":"jeev.io"},"Self":{"HostName":"prime"}}' host.example)"
eq "login: not json" foreign "$(classify_login 'not json' host.example)"

# state_file_login: the stopped-stack check.
tmp=$(mktemp -d)
eq "state: missing" logged-out "$(state_file_login "$tmp/none")"
printf '{}' >"$tmp/s"
eq "state: empty object" logged-out "$(state_file_login "$tmp/s")"
cur=$(printf 'a1b2' | base64 -w0)
profiles=$(printf '{"a1b2":{"ID":"a1b2","Name":"x"}}' | base64 -w0)
printf '{"_current-profile":"%s","_profiles":"%s"}' "$cur" "$profiles" >"$tmp/s"
eq "state: live login" logged-in "$(state_file_login "$tmp/s")"
printf '{"_current-profile":"%s","_profiles":"%s"}' "$cur" "$(printf '{}' | base64 -w0)" >"$tmp/s"
eq "state: dangling pointer" logged-out "$(state_file_login "$tmp/s")"
# tailscaled's real shape: _current-profile holds the profile's state key
# ("profile-<ID>"), which is the Key field of its _profiles entry.
cur=$(printf 'profile-646f' | base64 -w0)
profiles=$(printf '{"646f":{"ID":"646f","Key":"profile-646f","Name":"x"}}' | base64 -w0)
printf '{"_current-profile":"%s","_machinekey":"x","_profiles":"%s","profile-646f":"x"}' "$cur" "$profiles" >"$tmp/s"
eq "state: live login, real shape" logged-in "$(state_file_login "$tmp/s")"
printf '{"_current-profile":"%s","_profiles":"%s"}' "$cur" "$(printf '{"77aa":{"ID":"77aa","Key":"profile-77aa"}}' | base64 -w0)" >"$tmp/s"
eq "state: dangling pointer, real shape" logged-out "$(state_file_login "$tmp/s")"
printf 'garbage' >"$tmp/s"
nok state_file_login "$tmp/s"
printf '{"_current-profile":"%s","_profiles":"@@@"}' "$cur" >"$tmp/s"
nok state_file_login "$tmp/s"
rm -rf "$tmp"

# proxy_port and authkey_file read `docker compose config --format json`.
cfg='{"services":{"agent":{"secrets":[{"source":"authkey","target":"authkey"}]},"netguard":{"ports":[{"target":22,"published":"2222","host_ip":"127.0.0.1"},{"target":1055,"published":"10551","host_ip":"127.0.0.1"}]}},"secrets":{"authkey":{"name":"p_authkey","file":"/home/u/.cache/key"}}}'
eq "proxy port" 10551 "$(proxy_port "$cfg")"
nok proxy_port '{"services":{"netguard":{"ports":[{"target":1055,"published":"10551","host_ip":"0.0.0.0"}]}}}'
nok proxy_port '{"services":{"netguard":{}}}'
eq "authkey file" /home/u/.cache/key "$(authkey_file "$cfg")"
nok authkey_file '{"services":{"agent":{}},"secrets":{"authkey":{"file":"/k"}}}'
nok authkey_file '{"services":{"agent":{"secrets":[{"source":"authkey"}]}}}'

# parse_args requires --host-peer, a tailnet IPv4 address.
nok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p 2>/dev/null"
nok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p --host-peer 10.0.0.1 2>/dev/null"
nok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p --host-peer 100.79.139.70/32 2>/dev/null"
ok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p --host-peer 100.79.139.70 && [[ \$HOST_PEER == 100.79.139.70 ]]"

# tmpl keeps & and backslashes in values literally.
eq "tmpl" 'curl http://a&b\c:8080/ -o x' "$(tmpl 'curl http://@H@:@P@/ -o x' H 'a&b\c' P 8080)"

if ((fails)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all harness tests passed"
