#!/usr/bin/env bash
# Entrypoint for the e2e target node, run as root in the profile image. Joins
# the test tailnet with the auth key in the compose secret and serves $NONCE
# on port 8080.
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

tailscale up --auth-key=file:/run/secrets/authkey --hostname="argus-e2e-target-$RUN_ID"

# The image has no python3. perl-base is Essential in Ubuntu, so perl is always
# there. One listening socket serves the probes in turn.
# shellcheck disable=SC2016 # perl code, not shell
exec perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalPort => 8080, Listen => 16, ReuseAddr => 1) or die "listen: $!\n";
  while (my $c = $s->accept) {
    while (my $l = <$c>) { last if $l =~ /^\r?\n$/ }
    print $c "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " . length($ENV{NONCE}) .
      "\r\nConnection: close\r\n\r\n$ENV{NONCE}";
    close $c;
  }'
