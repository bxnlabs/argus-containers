#!/usr/bin/env bash
# Entrypoint for the e2e target node, run as root in the profile image. Joins
# the test tailnet with the auth key at /run/e2e/authkey and serves $NONCE on
# port 8080.
set -euo pipefail
: "${NONCE:?NONCE must be set}" "${RUN_ID:?RUN_ID must be set}"

sock=/var/run/tailscale/tailscaled.sock
tailscaled --tun=userspace-networking --state=mem: --socket="$sock" >/var/log/tailscaled.log 2>&1 &
for _ in $(seq 30); do
  [ -S "$sock" ] && break
  sleep 1
done
if [ ! -S "$sock" ]; then
  echo "tailscaled did not start" >&2
  cat /var/log/tailscaled.log >&2
  exit 1
fi

tailscale up --auth-key=file:/run/e2e/authkey --hostname="argus-e2e-target-$RUN_ID"

mkdir -p /srv
printf '%s' "$NONCE" >/srv/index.html
exec python3 -m http.server 8080 --directory /srv
