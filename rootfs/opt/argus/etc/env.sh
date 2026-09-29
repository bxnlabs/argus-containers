# shellcheck shell=sh
# Session environment for Argus profiles. Each profile's post_create hook
# sources this file, so agent sessions, their subprocesses and interactive
# shells all see it. Keep it out of the image ENV: if tailscaled is down,
# every proxied request fails, and builds and supervisord must not depend on
# the proxy.
#
# tailscaled runs in userspace mode, so tailnet names and addresses are
# reachable only through its proxy on localhost:1055. The proxy dials
# non-tailnet destinations directly, so internet egress keeps working.
ARGUS_PROXY=http://localhost:1055
export ALL_PROXY="$ARGUS_PROXY" all_proxy="$ARGUS_PROXY"
export HTTP_PROXY="$ARGUS_PROXY" http_proxy="$ARGUS_PROXY"
export HTTPS_PROXY="$ARGUS_PROXY" https_proxy="$ARGUS_PROXY"
export NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
unset ARGUS_PROXY
