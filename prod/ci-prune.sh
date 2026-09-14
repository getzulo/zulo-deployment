#!/usr/bin/env bash
# Drop unused Docker build cache on the CI host. The panel can ask for the same
# thing via check-node.sh; this timer is what keeps the disk from filling when
# nobody opens Infrastructure.
#
#   ./ci-prune.sh            # run once
#   ./ci-prune.sh --install  # daily timer at 04:00 UTC
set -euo pipefail

if pgrep -f 'Runner.Worker|buildkitd|docker build' >/dev/null; then
  echo "skip: a build is running"
  exit 0
fi

docker builder prune -af
docker image prune -f
df -h /

install_timer() {
  cat > /etc/systemd/system/zuloone-ci-prune.service <<EOF
[Unit]
Description=Prune unused Docker build cache on the CI host

[Service]
Type=oneshot
ExecStart=$(readlink -f "$0")
EOF
  cat > /etc/systemd/system/zuloone-ci-prune.timer <<'EOF'
[Unit]
Description=Daily unused Docker build-cache prune

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now zuloone-ci-prune.timer
  echo "Installed. Next: systemctl list-timers zuloone-ci-prune.timer"
}

[ "${1:-}" = "--install" ] && install_timer
