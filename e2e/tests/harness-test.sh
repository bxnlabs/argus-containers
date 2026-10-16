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
nok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p --host-peer 100.64.0.1/32 2>/dev/null"
ok bash -c ". '$here/../tailnet-separation.sh'; parse_args --profile p --host-peer 100.64.0.1 && [[ \$HOST_PEER == 100.64.0.1 ]]"

# -h prints the header comment and nothing else.
help=$("$here/../tailnet-separation.sh" -h)
eq "help: last line" "# run aborts before its assertions." "$(tail -n 1 <<<"$help")"
eq "help: first line" "# Tailnet-separation e2e for a dockerized Argus profile: the profile's" "$(head -n 1 <<<"$help")"

# caps_exactly_net_admin reads /proc/<pid>/status text.
ok caps_exactly_net_admin $'Name:\tx\nCapEff:\t0000000000001000\nCapBnd:\t0000000000001000'
nok caps_exactly_net_admin $'CapEff:\t0000000000001000\nCapBnd:\t0000000000003000'
nok caps_exactly_net_admin $'CapEff:\t0000000000000000\nCapBnd:\t0000000000001000'
nok caps_exactly_net_admin $'CapEff:\t0000000000001000'
nok caps_exactly_net_admin ''

# remove_leftover_targets: a target whose node has exited can't be logged
# out, but removing its project is enough; only a failed removal is fatal.
for case in "exec-fails:0" "down-fails:1"; do
  out=$(MODE=${case%%:*} bash -c '
    . "$1"
    log() { :; }
    compose_target() {
      case "$MODE:$2" in
        exec-fails:exec | down-fails:down) return 1 ;;
      esac
    }
    remove_leftover_targets e2e-tailnet-target-1a2b3c4d; echo "rc=$?"' _ "$here/../tailnet-separation.sh" 2>/dev/null)
  eq "leftover targets: ${case%%:*}" "rc=${case#*:}" "$out"
done

# logout_owned_login still logs out when the restarts and the health wait
# fail, and reports the failure.
tmp=$(mktemp -d)
out=$(LOG=$tmp/calls bash -c '
  . "$1"
  DEADLINE=0
  compose() {
    printf "%s\n" "$*" >>"$LOG"
    case "$*" in
      "restart "*) return 1 ;;
      "exec -T netguard tailscale status --json") echo "{\"BackendState\":\"NeedsLogin\"}" ;;
      "exec -T netguard /opt/argus/bin/netguard.sh --check") return 1 ;;
    esac
  }
  sleep() { :; }
  logout_owned_login; echo "rc=$?"' _ "$here/../tailnet-separation.sh")
eq "logout: reports the failed restarts" "rc=1" "$(tail -n 1 <<<"$out")"
ok grep -qx "exec -T netguard tailscale logout" "$tmp/calls"
ok grep -qx "exec -T netguard tailscale status --json" "$tmp/calls"
ok grep -q "restart -t 5 agent" "$tmp/calls"
rm -rf "$tmp"

# teardown survives a second signal: TERM during the agent logout must not
# stop it before the target logout.
tmp=$(mktemp -d)
LOG=$tmp/steps bash -c '
  . "$1"
  log() { :; }
  OWN_LOGIN=1 TARGET_STARTED=1 STACK_WAS_UP=1 TEARDOWN_ERRORS=0 TARGET_PROJECT=t
  logout_owned_login() { kill -TERM $$; sleep 0.3; echo agent >>"$LOG"; }
  logout_target() { echo target >>"$LOG"; }
  trap teardown EXIT
  exit 0' _ "$here/../tailnet-separation.sh" >/dev/null 2>&1
eq "teardown: both logouts after a second signal" $'agent\ntarget' "$(cat "$tmp/steps" 2>/dev/null)"
rm -rf "$tmp"

# A7 against hooks sourced in an empty environment, with a stand-in proxy
# that answers only a proxied request for the target. The recipe's hook comes
# from README.md, so the recipe and A7 can't drift apart.
tmp=$(mktemp -d)
python3 -I -c '
import http.server, os, sys
target, nonce, portfile = sys.argv[1:4]
class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "http://%s:8080/" % target
        body = (nonce if ok else "not a proxied request for the target").encode()
        self.send_response(200 if ok else 502)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Proxy)
with open(portfile + ".tmp", "w") as f:
    f.write(str(server.server_port))
os.replace(portfile + ".tmp", portfile)
server.serve_forever()' a7-target.invalid a7-nonce "$tmp/port" &
proxy_pid=$!
for _ in $(seq 50); do
  [[ -s $tmp/port ]] && break
  sleep 0.1
done
port=$(cat "$tmp/port")
recipe_hook=$(awk '/^### hooks\/post_create\.sh$/ { h = 1 } h && /^```sh$/ { c = 1; next } c && /^```$/ { exit } c' "$here/../../README.md")

# a7_with_hook HOOK: A7's verdict when the profile's hook is HOOK.
a7_with_hook() {
  printf '%s\n' "$1" >"$tmp/hook.sh"
  PROXY_PORT=$port TARGET_NAME=a7-target.invalid NONCE=a7-nonce HOOK=$tmp/hook.sh bash -c '
    . "$1"
    # The command runs in a child of the shell that sourced the hook, as it
    # does under `argus profile exec`, so it sees only exported variables.
    # shellcheck disable=SC2016 # expands in the inner shell
    on_host_hooked() { OUT=$(env -i PATH="$PATH" bash -c ". \"\$1\"; exec bash -c \"\$2\"" _ "$HOOK" "$1" 2>&1); }
    if a7_hook_exports_tailnet_proxy; then echo pass; else echo fail; fi' _ "$here/../tailnet-separation.sh"
}
# shellcheck disable=SC2016 # the hooks expand when sourced
{
  eq "a7: README.md has a recipe hook" yes "$([[ -n $recipe_hook ]] && echo yes)"
  eq "a7: the recipe's hook" pass "$(a7_with_hook "${recipe_hook//10551/$port}")"
  eq "a7: a session-wide hook" fail "$(a7_with_hook "p=http://127.0.0.1:$port"'
export ALL_PROXY=$p all_proxy=$p HTTP_PROXY=$p http_proxy=$p HTTPS_PROXY=$p https_proxy=$p')"
  eq "a7: one session-wide variable as well" fail "$(a7_with_hook "export ARGUS_TAILNET_PROXY=http://127.0.0.1:$port https_proxy=http://127.0.0.1:$port")"
  eq "a7: an unexported assignment" fail "$(a7_with_hook "ARGUS_TAILNET_PROXY=http://127.0.0.1:$port")"
  eq "a7: the wrong port" fail "$(a7_with_hook "export ARGUS_TAILNET_PROXY=http://127.0.0.1:1$port")"
}
kill "$proxy_pid"
rm -rf "$tmp"

# unreachable_cmd passes only on EHOSTUNREACH or ENETUNREACH. The stubbed
# timeout stands in for the connect, which bash -c inherits as an exported
# function.
# shellcheck disable=SC2329 # invoked by the inner bash
timeout() { [[ -n $STUB_OUT ]] && echo "$STUB_OUT"; return "$STUB_RC"; }
export -f timeout
for case in "No route to host:1:pass" "Network is unreachable:1:pass" "Connection refused:1:fail" \
  ":124:fail" ":0:fail" "No route to host:124:fail"; do
  IFS=: read -r msg rc want <<<"$case"
  got=$(STUB_OUT=${msg:+"bash: connect: $msg"} STUB_RC=$rc bash -c "$(unreachable_cmd 192.0.2.1 22)" >/dev/null && echo pass || echo fail)
  eq "unreachable: ${msg:-no output}, rc $rc" "$want" "$got"
done
unset -f timeout
eq "unreachable: a real refusal" fail "$(bash -c "$(unreachable_cmd 127.0.0.1 1)" >/dev/null && echo pass || echo fail)"

# tmpl keeps & and backslashes in values literally.
eq "tmpl" 'curl http://a&b\c:8080/ -o x' "$(tmpl 'curl http://@H@:@P@/ -o x' H 'a&b\c' P 8080)"

if ((fails)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all harness tests passed"
