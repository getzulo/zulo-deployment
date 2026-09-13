#!/usr/bin/env bash
# Health check for a non-Postgres fleet role: etcd, mongo, app, ci.
# The panel publishes itself; do not install this as role=panel.
#
#   ROLE=etcd CP_URL=https://10.10.0.200:8443 ./check-node.sh --install
#   ROLE=mongo NODE=mongo CP_URL=https://10.10.0.200:8443 ./check-node.sh --install
#   ROLE=app  CP_URL=https://10.10.0.200:8443 ./check-node.sh --install
#   ROLE=ci   CP_URL=https://10.10.0.200:8443 ./check-node.sh --install
#
# Token: CP_TOKEN_FILE (default /etc/zuloone/node-token), same as check-cluster.sh.
set -uo pipefail

ROLE="${ROLE:-}"
NODE="${NODE:-$(hostname)}"
CP_URL="${CP_URL:-}"
CP_TOKEN_FILE="${CP_TOKEN_FILE:-/etc/zuloone/node-token}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://10.10.1.210:2379,http://10.10.2.210:2379,http://10.10.0.220:2379}"
MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
MONGO_PORT="${MONGO_PORT:-27017}"
REGISTRY_URL="${REGISTRY_URL:-http://127.0.0.1:5000/v2/}"
DISK_PATH="${DISK_PATH:-/}"
ALERT_CMD="${ALERT_CMD:-}"

UNIT=/etc/systemd/system/zuloone-node-check
worst=0
report=""

say()  { report+="$*"$'\n'; printf '%s\n' "$*"; }
ok()   { say "  [ ok ]   $*"; }
warn() { say "  [ WARN ] $*"; [ "$worst" -lt 1 ] && worst=1; }
crit() { say "  [ CRIT ] $*"; worst=2; }

tcp() {
  local host="$1" port="$2"
  timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

disk_check() {
  local path="$1"
  local use
  use="$(df --output=pcent "$path" 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ -z "${use:-}" ] && return 0
  if   [ "$use" -ge 90 ]; then crit "${path} ${use}% full"
  elif [ "$use" -ge 80 ]; then warn "${path} ${use}% full"
  else ok "${path} ${use}% used"
  fi
}

case "$ROLE" in
  etcd|mongo|app|ci) ;;
  panel) echo "The panel publishes its own heartbeat. Do not install role=panel." >&2; exit 2 ;;
  postgres) echo "Use check-cluster.sh for postgres." >&2; exit 2 ;;
  *) echo "ROLE must be etcd, mongo, app or ci." >&2; exit 2 ;;
esac

say "ZuloOne ${ROLE} check — ${NODE} — $(date -u '+%Y-%m-%d %H:%M:%SZ')"

case "$ROLE" in
  etcd)
    if command -v etcdctl >/dev/null 2>&1; then
      healthy="$(etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health --cluster 2>/dev/null \
                 | grep -c 'is healthy' || true)"
      case "${healthy:-0}" in
        3) ok "etcd: 3/3 healthy" ;;
        2) warn "etcd: 2/3 healthy — quorum holds, but one more loss freezes failover" ;;
        *) crit "etcd: only ${healthy:-0}/3 healthy — NO QUORUM" ;;
      esac
    else
      crit "etcdctl is not installed"
    fi
    disk_check /
    ;;
  mongo)
    if tcp "$MONGO_HOST" "$MONGO_PORT"; then ok "Mongo answers on ${MONGO_HOST}:${MONGO_PORT}"
    else crit "Mongo does not answer on ${MONGO_HOST}:${MONGO_PORT}"
    fi
    if command -v docker >/dev/null 2>&1; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi mongo; then ok "a mongo container is running"
      else warn "no container name matching mongo — it may still be a host install"
      fi
    fi
    disk_check /var/lib/docker
    ;;
  app)
    if systemctl is-active --quiet docker 2>/dev/null || docker info >/dev/null 2>&1; then ok "docker is up"
    else crit "docker is not running"
    fi
    if command -v docker >/dev/null 2>&1; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi traefik; then ok "traefik is running"
      else warn "no container name matching traefik"
      fi
    fi
    disk_check /var/lib/docker
    disk_check /
    ;;
  ci)
    if curl -sf --max-time 3 "$REGISTRY_URL" >/dev/null; then ok "registry answers at ${REGISTRY_URL}"
    else crit "registry does not answer at ${REGISTRY_URL}"
    fi
    disk_check /
    ;;
esac

case "$worst" in
  0) say "RESULT: healthy" ;;
  1) say "RESULT: DEGRADED" ;;
  2) say "RESULT: BROKEN" ;;
esac

publish_report() {
  [ -n "$CP_URL" ] || return 0
  if [ ! -r "$CP_TOKEN_FILE" ]; then
    echo "  [ note ] CP_URL is set but $CP_TOKEN_FILE is unreadable — not publishing" >&2
    return 0
  fi
  local status
  case "$worst" in 0) status=healthy ;; 1) status=degraded ;; *) status=broken ;; esac
  if ! NODE="$NODE" STATUS="$status" ROLE="$ROLE" python3 -c '
import datetime, json, os, sys
sys.stdout.write(json.dumps({
    "node": os.environ["NODE"],
    "role": os.environ["ROLE"],
    "status": os.environ["STATUS"],
    "report": sys.stdin.read(),
    "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}))' <<<"$report" \
      | curl -sk --fail-with-body --max-time 10 -o /dev/null \
             -X POST "${CP_URL%/}/api/infra/report" \
             -H "X-Node-Token: $(cat "$CP_TOKEN_FILE")" \
             -H 'Content-Type: application/json' \
             --data-binary @-
  then
    echo "  [ note ] could not publish to $CP_URL" >&2
  fi
}
publish_report

if [ "$worst" -ne 0 ]; then
  printf '%s' "$report" | logger -t zuloone-node-check
  [ -n "$ALERT_CMD" ] && printf '%s' "$report" | $ALERT_CMD
fi

install_timer() {
  cat > "${UNIT}.service" <<EOF
[Unit]
Description=ZuloOne ${ROLE} node check (${NODE})

[Service]
Type=oneshot
Environment="CP_URL=${CP_URL}"
Environment="CP_TOKEN_FILE=${CP_TOKEN_FILE}"
Environment="ROLE=${ROLE}"
Environment="NODE=${NODE}"
Environment="ETCD_ENDPOINTS=${ETCD_ENDPOINTS}"
Environment="MONGO_HOST=${MONGO_HOST}"
Environment="MONGO_PORT=${MONGO_PORT}"
Environment="REGISTRY_URL=${REGISTRY_URL}"
ExecStart=$(readlink -f "$0")
EOF
  cat > "${UNIT}.timer" <<'EOF'
[Unit]
Description=Run the ZuloOne node check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now zuloone-node-check.timer
  echo
  echo "Installed ${ROLE} as ${NODE}. History:  journalctl -u zuloone-node-check"
}

[ "${1:-}" = "--install" ] && install_timer
exit "$worst"
