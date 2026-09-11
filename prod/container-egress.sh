#!/usr/bin/env bash
# Lock tenant containers to the database and nothing else — including the host
# they run on, which needs a separate chain (see ZULOONE-HOST-IN below).
# Runs on zo-app-1.
# Idempotent: rebuilds the chain from scratch every time.
#
#   ./container-egress.sh                 # apply now
#   ./container-egress.sh --install       # apply + persist across reboot
#   ./container-egress.sh --status        # show the active rules
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY THE ROUTER CANNOT DO IT
#
# Containers leave this VM NATed behind the host's address (10.10.1.220), so on
# the MikroTik a tenant's packets are indistinguishable from the VM's own. Worse,
# traffic to anything else in 10.10.1.0/24 never reaches the router at all — it
# is switched. A container could therefore talk to unrelated machines on the
# subnet and no router rule would ever see it.
#
# So the boundary has to be here, on the host, at the point where packets leave
# the container bridge.
#
# WHY NOT ufw: Docker inserts its own rules into the FORWARD chain ahead of
# ufw's, so `ufw deny` does not apply to container traffic while still reporting
# the port as blocked. DOCKER-USER is the chain Docker guarantees it will
# traverse first and will never flush — it is the supported hook for exactly this.
#
# WHAT THE TENANT ACTUALLY NEEDS: nothing but Postgres. Audited against the
# source: the AI assistant, outbound integrations and e-mail are all disabled by
# default and throw before any HTTP; startup performs no network calls at all
# (no licence check, no telemetry, no OIDC metadata fetch for JWT). So
# default-deny is the correct posture, not an aggressive one.
set -euo pipefail

# Must match docker-compose.yml's `networks.edge`. Changing one without the
# other silently disables the lockdown.
BRIDGE="${BRIDGE:-zo-edge0}"
SUBNET="${SUBNET:-172.30.0.0/24}"

# Where tenants are allowed to go.
PG_NODES="${PG_NODES:-10.10.1.210 10.10.2.210}"
PG_PORT="${PG_PORT:-5432}"

# Extra TCP destinations, space-separated host:port. Resolved to A records at
# apply time — Google rotates smtp.gmail.com, so a yesterday-working hole can
# time out today; re-run this script after that. Empty = no extra hole.
# Example: SMTP_DESTS="smtp.gmail.com:587 smtp.gmail.com:465"
SMTP_DESTS="${SMTP_DESTS:-}"

UNIT=/etc/systemd/system/zuloone-container-egress.service

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

apply() {
  # Docker creates DOCKER-USER and jumps to it first from FORWARD. It never
  # flushes it, so rules survive `systemctl restart docker` — but NOT a reboot,
  # which is what --install is for.
  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -F DOCKER-USER

  # Return traffic. Without this every allow below would need a mirror rule.
  iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

  # Traefik <-> tenant live on the same bridge. With br_netfilter loaded (Docker
  # loads it) even same-bridge traffic traverses FORWARD, so without this line
  # the catch-all below would break the proxy hop itself.
  iptables -A DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j RETURN

  # The one permitted destination.
  for node in $PG_NODES; do
    iptables -A DOCKER-USER -i "$BRIDGE" -d "$node" -p tcp --dport "$PG_PORT" -j RETURN
  done

  # Optional: SMTP / Seq / similar. Must sit ABOVE the catch-all DROP.
  # Hostnames are resolved now; the rule matches the IP, not the name.
  if [ -n "$SMTP_DESTS" ]; then
    for spec in $SMTP_DESTS; do
      host="${spec%%:*}"
      port="${spec##*:}"
      if [ -z "$host" ] || [ "$host" = "$spec" ] || [ -z "$port" ]; then
        echo "SMTP_DESTS entry '$spec' is not host:port — skipped" >&2
        continue
      fi
      ips=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
      if [ -z "$ips" ]; then
        echo "SMTP_DESTS: $host did not resolve — skipped" >&2
        continue
      fi
      for ip in $ips; do
        iptables -A DOCKER-USER -i "$BRIDGE" -d "$ip" -p tcp --dport "$port" -j RETURN
      done
    done
  fi

  # Everything else leaving the bridge: the rest of the LAN, the unrelated
  # machines on it, link-local metadata endpoints, and the internet.
  iptables -A DOCKER-USER -i "$BRIDGE" -j DROP

  # Docker's own trailing RETURN, restored because we flushed the chain.
  iptables -A DOCKER-USER -j RETURN

  # --- the host itself ------------------------------------------------------
  # DOCKER-USER is reached only from FORWARD, and a packet addressed to this
  # machine's own address goes to INPUT instead — so everything above is blind to
  # it. Without this block a tenant reaches every service on zo-app-1: sshd today,
  # and the docker-socket-proxy on 2375 the moment the control plane lands, which
  # is root on the host from inside a container.
  #
  # The tenant needs NOTHING from its host, so this is a flat deny. Established
  # traffic is returned first, or replies to connections the host opened toward a
  # container would be dropped.
  #
  # Own chain rather than rules spliced into INPUT: idempotent, safe to flush, and
  # visible as a unit in `iptables -L`.
  iptables -N ZULOONE-HOST-IN 2>/dev/null || true
  iptables -F ZULOONE-HOST-IN
  iptables -C INPUT -i "$BRIDGE" -j ZULOONE-HOST-IN 2>/dev/null \
    || iptables -I INPUT 1 -i "$BRIDGE" -j ZULOONE-HOST-IN
  iptables -A ZULOONE-HOST-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  iptables -A ZULOONE-HOST-IN -j DROP

  # IPv6: Docker leaves it disabled by default, so the chain usually does not
  # exist. If it does, deny outright — nothing here needs it, and a half-open
  # v6 path would quietly bypass every rule above.
  if ip6tables -L DOCKER-USER -n >/dev/null 2>&1; then
    ip6tables -F DOCKER-USER
    ip6tables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    ip6tables -A DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j RETURN
    ip6tables -A DOCKER-USER -i "$BRIDGE" -j DROP
    ip6tables -A DOCKER-USER -j RETURN
  fi
}

status() {
  echo "DOCKER-USER (bridge ${BRIDGE}, subnet ${SUBNET}):"
  iptables -L DOCKER-USER -n -v --line-numbers
  echo
  echo "ZULOONE-HOST-IN — container traffic addressed to this host:"
  iptables -L ZULOONE-HOST-IN -n -v --line-numbers 2>/dev/null || echo "  MISSING — the host is exposed to every container"
  echo

  # Count what landed against what was asked for. Every way this list gets
  # truncated — a mangled systemd Environment=, a shell that word-split it, an
  # address typo'd into an existing rule — produces a chain that looks plausible
  # and silently strands one database node. A tenant then dies at the next
  # failover, not now, so assert it here where the cause is still visible.
  want="$(printf '%s\n' $PG_NODES | wc -l)"
  have="$(iptables -S DOCKER-USER | grep -c -- "--dport ${PG_PORT} -j RETURN" || true)"
  if [ "$have" -ne "$want" ]; then
    printf '\033[31mMISMATCH\033[0m: %s database node(s) configured (%s), %s rule(s) present.\n' \
      "$want" "$PG_NODES" "$have"
    printf '  Tenants will lose the database when Patroni elects a node that has no rule.\n\n'
  else
    echo "database nodes allowed: ${have}/${want} — ${PG_NODES}"
    echo
  fi
  if [ -n "$SMTP_DESTS" ]; then
    echo "extra TCP destinations: ${SMTP_DESTS}"
    echo
  fi

  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "bridge ${BRIDGE}: present"
  else
    echo "bridge ${BRIDGE}: NOT PRESENT — the stack has not been started yet."
    echo "  Rules are still installed and will match once it appears; iptables"
    echo "  resolves interface names at match time, not when the rule is added."
  fi
}

install_unit() {
  # Ordered After=docker.service because Docker recreates its chains on start;
  # applying before it would leave the rules in place but the jump missing.
  cat > "$UNIT" <<EOF
[Unit]
Description=ZuloOne container egress lockdown (DOCKER-USER)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$(readlink -f "$0")
Environment=BRIDGE=${BRIDGE}
Environment=SUBNET=${SUBNET}
# QUOTED, because PG_NODES holds two space-separated addresses. Unquoted, systemd
# splits the line into separate VAR=VAL assignments, decides the second address is
# not one, and logs "Invalid environment assignment, ignoring: <addr>" — then runs
# the service successfully with only the FIRST database node allowed.
# The result passes every test until Patroni fails over to the other node, at which
# point every tenant loses its database and this file still looks correct.
Environment="PG_NODES=${PG_NODES}"
Environment="SMTP_DESTS=${SMTP_DESTS}"

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now zuloone-container-egress.service
  log "Installed ${UNIT}"
}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

case "${1:-}" in
  --status) status; exit 0 ;;
  --install) apply; install_unit ;;
  "") apply ;;
  *) echo "usage: $0 [--install|--status]" >&2; exit 1 ;;
esac

log "Applied"
status

cat <<EOF

VERIFY from inside a tenant container — the first must succeed, the rest must
all hang until timeout. A refusal that comes back instantly is usually DNS or a
closed port, not the firewall; insist on a TIMEOUT.

  c=\$(docker ps -q -f name=tenant)
  docker exec \$c bash -c 'timeout 5 bash -c "</dev/tcp/${PG_NODES%% *}/${PG_PORT}" && echo PG-OK'
  docker exec \$c bash -c 'timeout 5 bash -c "</dev/tcp/10.10.0.210/5000"  || echo BLOCKED-registry'
  docker exec \$c bash -c 'timeout 5 bash -c "</dev/tcp/10.10.0.1/80"     || echo BLOCKED-gateway'
  docker exec \$c bash -c 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"      || echo BLOCKED-internet'

And confirm the proxy hop still works from outside:
  curl -fsS https://<tenant-host>/health
EOF
