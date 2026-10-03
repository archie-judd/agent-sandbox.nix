#!/usr/bin/env bash
# Manual Linux host test. Run from a normal terminal, NOT another sandbox:
#   bash debug/smoke-host-resolver.sh test.hatch.robintully.dev 192.168.1.150
# Does not edit DNS or deploy anything. Starts two temporary loopback-only
# systemd units, and stops them (including their children) on exit.
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -c /dev/net/tun ]; then
  echo 'Usage (in a normal Linux host terminal): bash debug/smoke-host-resolver.sh DOMAIN EXPECTED_A' >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
domain=$1 expected=$2
cd "$root"

# Check the host's split resolver before testing the bridge.
bind=$(nix-build --no-out-link -E '(import ./tests/pinned-nixpkgs.nix {}).bind.dnsutils')
dig="$bind/bin/dig"
if ! "$dig" @127.0.0.53 +time=2 +tries=1 +short "$domain" A | grep -Fxq "$expected"; then
  echo "Host stub does not return $expected for $domain; check host DNS first" >&2
  exit 1
fi
wrapper=$(nix-build --no-out-link debug/host-resolver-test.nix)
socat=$(nix-build --no-out-link -E '(import ./tests/pinned-nixpkgs.nix {}).socat')
sudo -v

# Use transient units so a failed test cannot leave a privileged listener
# behind. They bind 127.0.0.1 only; the host's normal DNS configuration stays
# untouched. Fail if some other service already owns this address/port.
unit="agent-sandbox-dns-smoke-$RANDOM-$$"
cleanup() {
  for protocol in udp tcp; do
    sudo -n systemctl stop "$unit-$protocol.service" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
sudo -n systemd-run --quiet --collect --unit="$unit-udp" \
  "$socat/bin/socat" 'UDP4-LISTEN:53,bind=127.0.0.1,reuseaddr,fork' 'UDP4:127.0.0.53:53'
sudo -n systemd-run --quiet --collect --unit="$unit-tcp" \
  "$socat/bin/socat" 'TCP4-LISTEN:53,bind=127.0.0.1,reuseaddr,fork' 'TCP4:127.0.0.53:53'
sleep 1
for protocol in udp tcp; do
  if ! sudo -n systemctl is-active --quiet "$unit-$protocol.service"; then
    echo "Temporary $protocol DNS listener failed to start; inspect its journal" >&2
    exit 1
  fi
done
for flag in '' '+tcp'; do
  if ! "$dig" @127.0.0.1 $flag +time=2 +tries=1 +short "$domain" A | grep -Fxq "$expected"; then
    echo "Host loopback listener failed for ${flag:-udp}" >&2
    exit 1
  fi
done

# The same two lookups, now through the opt-in wrapper's /etc/resolv.conf.
# A public name checks that this path uses the host's normal upstream too.
"$wrapper/bin/sandbox-host-dns-test" --norc --noprofile -c '
  read -r resolver < /etc/resolv.conf
  [ "$resolver" = "nameserver 10.0.2.2" ] || exit 1
  for flag in "" +tcp; do
    dig $flag +time=2 +tries=1 +short "$1" A | grep -Fxq "$2" || exit 1
  done
  dig +time=2 +tries=1 +short example.com A | grep -q . || exit 1
' _ "$domain" "$expected"
echo 'PASS: sandbox queried host split DNS over UDP and TCP; public DNS works'
