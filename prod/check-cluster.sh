#!/usr/bin/env bash
# Cluster and backup health for the ZuloOne Patroni cluster.
# Run on either data node — it works out which role it is playing.
#
#   ./check-cluster.sh            # human-readable, non-zero exit on trouble
#   ./check-cluster.sh --install  # + systemd timer, every 5 minutes
#
# Set CP_URL to also publish every run to the control plane, which is what makes
# the node visible on the Infrastructure screen:
#
#   CP_URL=https://10.10.0.200:8443 ./check-cluster.sh --install
#
# The token is read from CP_TOKEN_FILE (default /etc/zuloone/node-token) and must
# match Patroni__ReportToken on the control plane.
#
# Exits 0 healthy, 1 degraded, 2 broken. Anything non-zero also writes to the
# journal, so `journalctl -u zuloone-cluster-check` is the history.
#
# ---------------------------------------------------------------------------
# WHY
#
# Patroni handles failover and recovery on its own, so the failures left are the
# quiet ones — the kind that look fine until the moment you need them:
#
#   * etcd lost quorum. Patroni then REFUSES to promote anyone, because it cannot
#     prove the old leader is gone. Correct behaviour, invisible until an outage.
#   * A replica stopped streaming. Process up, port answering, systemd green.
#   * archive_command silently stopped delivering WAL, so the full backups you
#     have cannot be rolled forward.
#   * The data partition filling up, which takes Postgres down hard.
set -uo pipefail

PATRONI_CONF="${PATRONI_CONF:-/etc/patroni/config.yml}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://10.10.1.210:2379,http://10.10.2.210:2379,http://10.10.0.220:2379}"
LAG_WARN_BYTES="${LAG_WARN_BYTES:-16777216}"      # 16 MB
LAG_CRIT_BYTES="${LAG_CRIT_BYTES:-134217728}"     # 128 MB
BACKUP_WARN_HOURS="${BACKUP_WARN_HOURS:-30}"      # daily + slack
STANZA="${STANZA:-zuloone}"
ALERT_CMD="${ALERT_CMD:-}"

# Where to publish every run, so the panel can show this node. Empty disables it
# and the script behaves exactly as it did before.
CP_URL="${CP_URL:-}"
CP_TOKEN_FILE="${CP_TOKEN_FILE:-/etc/zuloone/node-token}"

UNIT=/etc/systemd/system/zuloone-cluster-check
worst=0
report=""

say()  { report+="$*"$'\n'; printf '%s\n' "$*"; }
ok()   { say "  [ ok ]   $*"; }
warn() { say "  [ WARN ] $*"; [ "$worst" -lt 1 ] && worst=1; }
crit() { say "  [ CRIT ] $*"; worst=2; }

psql_()  { sudo -u postgres psql -tAqX -c "$1" 2>/dev/null; }
patroni() { sudo -u postgres patronictl -c "$PATRONI_CONF" "$@" 2>&1; }

say "ZuloOne cluster check — $(hostname) — $(date -u '+%Y-%m-%d %H:%M:%SZ')"

# --- etcd quorum ------------------------------------------------------------
# First, because everything else depends on it. Two of three must be up; with one
# the cluster is read-only and Patroni will not act on a failure.
if command -v etcdctl >/dev/null 2>&1; then
  healthy="$(etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health --cluster 2>/dev/null \
             | grep -c 'is healthy' || true)"
  case "${healthy:-0}" in
    3) ok "etcd: 3/3 healthy" ;;
    2) warn "etcd: 2/3 healthy — quorum holds, but one more loss freezes failover" ;;
    *) crit "etcd: only ${healthy:-0}/3 healthy — NO QUORUM, Patroni cannot promote anyone" ;;
  esac
fi

# --- Patroni's own view -----------------------------------------------------
if [ ! -f "$PATRONI_CONF" ]; then
  crit "no Patroni config at $PATRONI_CONF"
  printf '%s' "$report" | logger -t zuloone-cluster-check
  exit 2
fi

if ! systemctl is-active --quiet patroni; then
  crit "patroni service is not running on this node"
fi

members="$(patroni list -f tsv)"
if printf '%s' "$members" | grep -qiE 'error|not find'; then
  crit "patronictl cannot read the cluster:"
  say "$(printf '%s' "$members" | head -3 | sed 's/^/         /')"
else
  # Columns: Cluster, Member, Host, Role, State, TL, Receive LSN, Receive Lag,
  # Replay LSN, Replay Lag. The CLUSTER NAME COMES FIRST — read the member fields
  # one position further right than feels natural, or every row reports the cluster
  # name as a broken member.
  leaders="$(printf '%s' "$members" | tail -n +2 | awk -F'\t' 'tolower($4) ~ /leader/' | wc -l)"
  case "$leaders" in
    1) ok "exactly one leader" ;;
    0) crit "NO leader — the cluster is not accepting writes" ;;
    *) crit "$leaders leaders reported — split brain" ;;
  esac

  # A replica that is "running" but not "streaming" has stopped following.
  while IFS=$'\t' read -r cl name host role state tl rlsn rlag rest; do
    [ -z "${name:-}" ] && continue
    case "$(printf '%s' "$role" | tr 'A-Z' 'a-z')" in
      *leader*) ok "${name}: leader" ;;
      *)
        if [ "$state" = "streaming" ]; then
          ok "${name}: streaming, replay lag ${rlag:-0}"
        else
          crit "${name}: state '${state}' — not streaming"
        fi ;;
    esac
  done <<EOF
$(printf '%s' "$members" | tail -n +2)
EOF
fi

# --- this node's own replication position -----------------------------------
if psql_ "SELECT 1" >/dev/null 2>&1; then
  if [ "$(psql_ 'SELECT pg_is_in_recovery()')" = "t" ]; then
    # Comparing LSNs, not the last-replay timestamp: on an idle leader nothing is
    # written, so the timestamp stops advancing and a healthy replica looks stale.
    lag_b="$(psql_ "SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0)::bigint")"
    if [ -z "$(psql_ 'SELECT pg_last_wal_receive_lsn()')" ]; then
      crit "receiving no WAL — replication from the leader is down"
    elif [ "${lag_b:-0}" -ge "$LAG_CRIT_BYTES" ]; then
      crit "$((lag_b/1048576)) MB received but not replayed"
    elif [ "${lag_b:-0}" -ge "$LAG_WARN_BYTES" ]; then
      warn "$((lag_b/1048576)) MB received but not replayed"
    else
      ok "caught up — everything received has been replayed"
    fi
  else
    n="$(psql_ 'SELECT count(*) FROM pg_stat_replication')"
    [ "${n:-0}" -gt 0 ] && ok "${n} replica(s) connected" \
                        || crit "no replica connected to this leader"
  fi
else
  warn "cannot reach the local Postgres (Patroni may be starting it)"
fi

# --- backups ----------------------------------------------------------------
if command -v pgbackrest >/dev/null 2>&1; then
  # Ask Postgres directly, BEFORE pgbackrest check, because check is not always
  # meaningful (see below) and this always is. failed_count is a lifetime counter
  # and says nothing on its own — a cluster that failed once at 3am and has worked
  # since carries it forever. What matters is whether the LAST attempt failed.
  if [ "$(psql_ 'SELECT pg_is_in_recovery()')" = "f" ]; then
    arch="$(psql_ 'SELECT archived_count FROM pg_stat_archiver')"
    # Asked as an explicit token, not a bare boolean: `psql -tA` prints a boolean
    # COLUMN as t/f, but a boolean CAST TO TEXT as true/false. Concatenating forces
    # the cast, so a `= "t"` test silently never matches and the check reports
    # success forever. Spell the answer out instead of relying on either rendering.
    lastfail_newer="$(psql_ "SELECT CASE
        WHEN COALESCE(last_failed_time,'-infinity') > COALESCE(last_archived_time,'-infinity')
        THEN 'STALE' ELSE 'FRESH' END FROM pg_stat_archiver")"
    if [ "${lastfail_newer:-STALE}" = "STALE" ]; then
      crit "archiver: last attempt FAILED ($(psql_ 'SELECT last_failed_wal FROM pg_stat_archiver')) — journalctl -u patroni | grep archive"
    elif [ "${arch:-0}" -eq 0 ]; then
      warn "archiver: nothing archived yet on this leader"
    else
      ok "archiver: ${arch} segments pushed, last attempt succeeded"
    fi

    # The definitive backlog signal. A segment stays .ready until archive_command
    # reports success, so this grows the moment archiving stalls — including the
    # case where archive_command hangs rather than failing, which the counters
    # above cannot see.
    pgdata="$(psql_ 'SHOW data_directory')"
    rdy=0
    [ -n "${pgdata:-}" ] && [ -d "${pgdata}/pg_wal/archive_status" ] \
      && rdy="$(find "${pgdata}/pg_wal/archive_status" -maxdepth 1 -name '*.ready' 2>/dev/null | wc -l)"
    if   [ "${rdy:-0}" -ge 500 ]; then crit "${rdy} WAL segments waiting to archive — pg_wal will fill"
    elif [ "${rdy:-0}" -ge 50 ];  then warn "${rdy} WAL segments waiting to archive"
    else ok "WAL archive queue: ${rdy:-0}"
    fi
  fi

  # `check` validates archive_command end to end — but ONLY against a cluster it
  # knows to be the primary. On a node whose config lists just itself, running as a
  # standby, there is no primary to test and check exits 0 having verified nothing:
  #
  #   INFO: check repo1 (standby)
  #   INFO: switch wal not performed because this is a standby
  #
  # That vacuous pass is why this section leads with pg_stat_archiver. Say plainly
  # which of the two happened rather than printing "passes" for both.
  chk=""
  if ! chk="$(sudo -u postgres pgbackrest --stanza="$STANZA" --log-level-console=info check 2>&1)"; then
    crit "pgbackrest check FAILED — WAL archiving is broken, PITR is not available"
  elif printf '%s' "$chk" | grep -q 'archive for WAL (primary)'; then
    ok "pgbackrest check passes (WAL round-trip verified against the primary)"
  else
    ok "pgbackrest check passes — repository reachable (archive round-trip NOT tested from this node)"
  fi

  last="$(sudo -u postgres pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null \
          | grep -o '"stop":[0-9]*' | tail -1 | cut -d: -f2)"
  if [ -n "${last:-}" ]; then
    age_h=$(( ( $(date +%s) - last ) / 3600 ))
    [ "$age_h" -ge "$BACKUP_WARN_HOURS" ] && warn "last backup ${age_h}h old" \
                                          || ok "last backup ${age_h}h old"
  else
    warn "no completed backup found for stanza '${STANZA}'"
  fi
fi

# --- disk -------------------------------------------------------------------
# A full data partition takes Postgres down hard, and WAL accumulates fastest
# exactly when replication is already broken — the two failures compound.
use="$(df --output=pcent /var/lib/postgresql 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${use:-}" ]; then
  if   [ "$use" -ge 90 ]; then crit "data partition ${use}% full"
  elif [ "$use" -ge 80 ]; then warn "data partition ${use}% full"
  else ok "data partition ${use}% used"
  fi
fi

case "$worst" in
  0) say "RESULT: healthy" ;;
  1) say "RESULT: DEGRADED" ;;
  2) say "RESULT: BROKEN" ;;
esac

# --- publish to the control plane -------------------------------------------
# ALWAYS, not only on trouble. The panel needs to tell three states apart:
#
#   healthy            -- a fresh report saying so
#   the check is dead  -- no report for a while
#   the node is gone   -- likewise
#
# If a healthy run stayed silent, the last two would be indistinguishable from
# the first, and the panel would keep displaying a stale "healthy" long after the
# machine stopped saying anything. Publishing every five minutes inverts that:
# silence becomes the alarm, and it cannot be missed by losing one message.
#
# Note this is the opposite policy from ALERT_CMD below, which is for paging a
# human and correctly stays quiet when there is nothing to say.
publish_report() {
  [ -n "$CP_URL" ] || return 0
  if [ ! -r "$CP_TOKEN_FILE" ]; then
    echo "  [ note ] CP_URL is set but $CP_TOKEN_FILE is unreadable — not publishing" >&2
    return 0
  fi

  local status
  case "$worst" in 0) status=healthy ;; 1) status=degraded ;; *) status=broken ;; esac

  # The pgBackRest inventory rides along with the health report.
  #
  # Those backups are the fleet's actual disaster recovery and they were invisible
  # from the panel — it could show per-tenant dumps and nothing about the cluster
  # they all sit on. Sending it here rather than building a channel to this host
  # costs one command: the node is already talking every five minutes, and it is
  # the only machine that can answer.
  #
  # Empty object on failure, never a missing key: the panel must be able to tell
  # "no backups" from "could not ask".
  local backups
  backups="$(sudo -u postgres pgbackrest --stanza="$STANZA" --output=json info 2>/dev/null || echo '[]')"

  # JSON assembled by python3 rather than by hand: the report contains newlines,
  # quotes and the odd backslash from a path, and hand-rolled escaping here would
  # fail on exactly the reports that matter most. python3 is already a hard
  # dependency on these hosts — Patroni is written in it.
  #
  # -k is deliberate. The control plane presents a Cloudflare Origin CA
  # certificate, which chains to a root no system trust store carries, and this
  # request never leaves the 10.x network. Forging it would require already being
  # positioned to redirect internal traffic, at which point a faked health report
  # is far from the worst available move.
  if ! NODE="$(hostname)" STATUS="$status" BACKUPS="$backups" python3 -c '
import datetime, json, os, sys
try:
    backups = json.loads(os.environ.get("BACKUPS") or "[]")
except ValueError:
    backups = []
sys.stdout.write(json.dumps({
    "node": os.environ["NODE"],
    "status": os.environ["STATUS"],
    "report": sys.stdin.read(),
    "backups": backups,
    "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}))' <<<"$report" \
      | curl -sk --fail-with-body --max-time 10 -o /dev/null \
             -X POST "${CP_URL%/}/api/infra/report" \
             -H "X-Node-Token: $(cat "$CP_TOKEN_FILE")" \
             -H 'Content-Type: application/json' \
             --data-binary @-
  then
    # --fail-with-body above is load-bearing. Without it curl exits 0 for ANY
    # response it managed to receive, so a 404 from a control plane that does not
    # have this endpoint, or a 401 from a stale token, both looked like a
    # successful publish — the exact failure this reporting exists to prevent.
    #
    # Never fatal, though. The panel going missing must not make a healthy cluster
    # report itself broken: this script's exit code is about the DATABASE.
    echo "  [ note ] could not publish to $CP_URL" >&2
  fi
}
publish_report

if [ "$worst" -ne 0 ]; then
  printf '%s' "$report" | logger -t zuloone-cluster-check
  [ -n "$ALERT_CMD" ] && printf '%s' "$report" | $ALERT_CMD
fi

install_timer() {
  cat > "${UNIT}.service" <<EOF
[Unit]
Description=ZuloOne Patroni cluster and backup check

[Service]
Type=oneshot
# QUOTED. systemd splits Environment= on whitespace, so an unquoted value
# containing a space silently becomes a different, shorter setting — the failure
# mode that once turned a two-node PG_NODES list into one node.
Environment="CP_URL=${CP_URL}"
Environment="CP_TOKEN_FILE=${CP_TOKEN_FILE}"
ExecStart=$(readlink -f "$0")
EOF
  cat > "${UNIT}.timer" <<'EOF'
[Unit]
Description=Run the ZuloOne cluster check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now zuloone-cluster-check.timer
  echo
  echo "Installed. History:  journalctl -u zuloone-cluster-check"
}

[ "${1:-}" = "--install" ] && install_timer
exit "$worst"
