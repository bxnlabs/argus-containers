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

# uncovered_routes: Review Focus #1 (exit node, subnet routes).
table52=$'100.65.124.11 dev tailscale0 \n100.100.100.100 dev tailscale0 \nthrow 127.0.0.0/8 \n192.168.1.0/24 dev tailscale0 \ndefault dev tailscale0 '
eq "uncovered: subnet and exit node" $'192.168.1.0/24\n0.0.0.0/0' "$(uncovered_routes 100.64.0.0/10 <<<"$table52")"
eq "uncovered: comma list covers subnet" "0.0.0.0/0" "$(uncovered_routes '100.64.0.0/10, 192.168.0.0/16' <<<"$table52")"
eq "uncovered: multi-line list covers subnet" "0.0.0.0/0" "$(uncovered_routes $'100.64.0.0/10,\n192.168.0.0/16' <<<"$table52")"
eq "uncovered: host peers only" "" "$(uncovered_routes 100.64.0.0/10 <<<$'100.65.124.11 dev tailscale0 \n100.100.100.100 dev tailscale0 ')"
eq "uncovered: empty table" "" "$(uncovered_routes 100.64.0.0/10 </dev/null)"

# classify_login
eq "login: logged out" logged-out "$(classify_login '{"BackendState":"NeedsLogin","Self":{"HostName":"prime"}}' e2e.example)"
eq "login: abandoned e2e" e2e "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"e2e.example"},"Self":{"HostName":"argus-e2e-agent-1a2b3c4d"}}' e2e.example)"
eq "login: e2e name on another tailnet" foreign "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"jeev.io"},"Self":{"HostName":"argus-e2e-agent-1a2b3c4d"}}' e2e.example)"
eq "login: real login" foreign "$(classify_login '{"BackendState":"Running","CurrentTailnet":{"Name":"e2e.example"},"Self":{"HostName":"prime"}}' e2e.example)"
eq "login: stopped but logged in" foreign "$(classify_login '{"BackendState":"Stopped","CurrentTailnet":{"Name":"jeev.io"},"Self":{"HostName":"prime"}}' e2e.example)"
eq "login: not json" foreign "$(classify_login 'not json' e2e.example)"

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
printf 'garbage' >"$tmp/s"
nok state_file_login "$tmp/s"
printf '{"_current-profile":"%s","_profiles":"@@@"}' "$cur" >"$tmp/s"
nok state_file_login "$tmp/s"
rm -rf "$tmp"

# marker_result: Review Focus #5. ($(...) strips the trailing newline of the
# body, so expectations end without one.)
id=deadbeef-3-12345
pane="user@prime ~ % printf '%s:%s:%s\n' ARGUS-E2E BEGIN $id; cmd; printf '%s:%s:%s:rc=%d\n' ARGUS-E2E END $id \$?
ARGUS-E2E:BEGIN:$id
line one
line two
ARGUS-E2E:END:$id:rc=0
user@prime ~ %"
eq "marker: body and rc" $'rc=0\nline one\nline two' "$(marker_result "$id" <<<"$pane")"
eq "marker: nonzero rc" "rc=3" "$(marker_result x <<<$'ARGUS-E2E:BEGIN:x\nARGUS-E2E:END:x:rc=3')"
eq "marker: no trailing newline" $'rc=0\nfoo' "$(marker_result x <<<$'ARGUS-E2E:BEGIN:x\nfooARGUS-E2E:END:x:rc=0')"
eq "marker: other ids ignored" $'rc=0\nmine' "$(marker_result x <<<$'ARGUS-E2E:BEGIN:y\ntheirs\nARGUS-E2E:END:y:rc=1\nARGUS-E2E:BEGIN:x\nmine\nARGUS-E2E:END:x:rc=0')"
nok marker_result x <<<$'ARGUS-E2E:BEGIN:x\nstill running'
nok marker_result x <<<"printf '%s:%s:%s\n' ARGUS-E2E BEGIN x; sleep 9; printf '%s:%s:%s:rc=%d\n' ARGUS-E2E END x \$?"
nok marker_result x <<<$'ARGUS-E2E:BEGIN:x\nARGUS-E2E:END:x:rc=abc'

# strip_ctrl
eq "strip_ctrl" $'a\tb\nc' "$(printf 'a\tb\r\n\033[31mc' | strip_ctrl | sed 's/\[31m//')"

# tmpl keeps & and backslashes in values literally.
eq "tmpl" 'curl http://a&b\c:8080/ -o x' "$(tmpl 'curl http://@H@:@P@/ -o x' H 'a&b\c' P 8080)"

if ((fails)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all harness tests passed"
