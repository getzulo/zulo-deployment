#!/usr/bin/env bash
# Run once on each freshly installed VM. Ubuntu leaves root locked, so this goes
# through sudo:
#
#   scp first-boot.sh <you>@<ip>:/tmp/
#   ssh <you>@<ip> 'sudo bash /tmp/first-boot.sh'
#
# Installs the handful of packages every node needs, then VERIFIES the machine
# against the plan in INSTALL.md §0.3 — address, netmask, gateway, DNS, and
# whether the router will actually carry traffic to the other tiers.
#
# The verification is the point. A wrong gateway or netmask produces a VM that
# boots perfectly and routes nowhere, and the symptom does not surface until
# Phase 3 fails to clone a standby — by which time it looks like a Postgres
# problem. Catch it here instead.
set -uo pipefail

# The plan. Keep in step with INSTALL.md §0.3.
#   hostname : address/prefix : gateway
PLAN="
zo-pg-1:10.10.1.210/24:10.10.1.1
zo-app-1:10.10.1.220/24:10.10.1.1
zo-ci-1:10.10.0.210/24:10.10.0.1
zo-pg-2:10.10.2.210/24:10.10.2.1
zo-pgw-1:10.10.0.220/24:10.10.0.1
zo-cp-1:10.10.0.200/24:10.10.0.1
"
# Pre-existing resolver, and it lives in the DATA subnet — so every tier needs
# an explicit DNS rule on the router to reach it (mikrotik.rsc section 5).
DNS_EXPECTED="${DNS_EXPECTED:-10.10.2.10}"
# One gateway per tier — reachability across all three proves inter-tier routing.
TIER_GATEWAYS="${TIER_GATEWAYS:-10.10.0.1 10.10.1.1 10.10.2.1}"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

host="$(hostnamectl --static 2>/dev/null || hostname)"
row="$(printf '%s\n' "$PLAN" | grep "^${host}:" || true)"
if [ -z "$row" ]; then
  echo "Hostname '${host}' is not in the plan. Set it first:" >&2
  echo "  hostnamectl set-hostname zo-pg-1     # or whichever this is" >&2
  echo "Known: $(printf '%s\n' "$PLAN" | grep -o '^zo-[a-z0-9-]*' | tr '\n' ' ')" >&2
  exit 1
fi
want_cidr="$(echo "$row" | cut -d: -f2)"
want_gw="$(echo "$row" | cut -d: -f3)"

head_ "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get -y -qq upgrade
# open-vm-tools is what lets vCenter shut the guest down gracefully instead of
# pulling the power — it matters most on the database nodes.
apt-get install -y -qq --no-install-recommends \
  open-vm-tools qemu-guest-agent curl ca-certificates gnupg sudo >/dev/null
ok "installed"

head_ "Identity"
ok "hostname ${host}"
grep -q "$host" /etc/hosts || bad "/etc/hosts has no entry for ${host} — sudo will warn on every call"

head_ "Network vs the plan (${want_cidr}, gw ${want_gw})"
iface="$(ip -o -4 route show default | awk '{print $5; exit}')"
[ -n "$iface" ] && ok "interface ${iface}" || bad "no default route at all"

have_cidr="$(ip -o -4 addr show "${iface:-lo}" | awk '{print $4; exit}')"
[ "$have_cidr" = "$want_cidr" ] \
  && ok "address ${have_cidr}" \
  || bad "address is ${have_cidr:-none}, plan says ${want_cidr}"

have_gw="$(ip -o -4 route show default | awk '{print $3; exit}')"
[ "$have_gw" = "$want_gw" ] \
  && ok "gateway ${have_gw}" \
  || bad "gateway is ${have_gw:-none}, plan says ${want_gw} — this VM will not route"

# Ubuntu runs systemd-resolved, so /etc/resolv.conf is a symlink to a stub file
# containing only `nameserver 127.0.0.53` — the real upstreams never appear there.
# Grepping the file reports a false failure while name resolution plainly works.
# Ask resolvectl when it exists; fall back to the file when it does not.
if command -v resolvectl >/dev/null 2>&1; then
  configured_dns="$(resolvectl dns 2>/dev/null)"
  dns_source="resolvectl"
else
  configured_dns="$(cat /etc/resolv.conf 2>/dev/null)"
  dns_source="/etc/resolv.conf"
fi

if printf '%s' "$configured_dns" | grep -q "$DNS_EXPECTED"; then
  ok "resolver ${DNS_EXPECTED} (via ${dns_source})"
else
  # Still worth failing on even when lookups succeed: a DHCP-supplied resolver
  # also resolves — right up to the point where it does not know your internal
  # names, which is a confusing failure to meet in Phase 3.
  bad "resolver is not ${DNS_EXPECTED} — ${dns_source} reports: $(printf '%s' "$configured_dns" | tr '\n' ' ' | tr -s ' ' | cut -c1-140)"
fi

head_ "Reachability"
for gw in $TIER_GATEWAYS; do
  if ping -c1 -W2 "$gw" >/dev/null 2>&1; then
    ok "$gw reachable"
  else
    # Only the VM's own gateway is fatal here; the others depend on router policy
    # that may legitimately not be in place yet.
    [ "$gw" = "$want_gw" ] && bad "$gw UNREACHABLE — this is the VM's own gateway" \
                           || bad "$gw unreachable (inter-tier routing or policy)"
  fi
done

if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  ok "DNS resolves"
else
  bad "DNS does not resolve — check the resolver and the router's DNS policy"
fi

head_ "Result"
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  echo "  Ready. Next: copy your SSH key (INSTALL.md Phase 2)."
  exit 0
fi
cat <<EOF

  Fix before continuing. Network settings live in /etc/netplan/*.yaml; apply
  with 'netplan try' (auto-reverts after 120s if you lose the session), then
  'netplan apply'. Full plan: INSTALL.md §0.3.

  A wrong gateway is the one that wastes the most time later — the VM looks
  healthy and only fails when something has to cross tiers.
EOF
exit 1
