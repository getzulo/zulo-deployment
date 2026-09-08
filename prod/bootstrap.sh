#!/usr/bin/env bash
# Bootstrap an Ubuntu Server 26.04 VM for the ZuloOne app tier. Idempotent.
# Root is locked on Ubuntu, so this runs through sudo:
#
#   ssh <you>@10.10.1.220 'sudo bash -s' < bootstrap.sh              # zo-app-1
#   ssh <you>@10.10.0.210 'sudo ROLE=ci bash -s' < bootstrap.sh      # zo-ci-1
#
# Installs Docker, creates a non-root `deploy` user, hardens SSH, and — on the
# CI node only — starts the image registry. It does NOT configure the firewall:
# that lives on the MikroTik (mikrotik.rsc) and must be in place BEFORE the
# stack goes up. Do not substitute ufw; Docker writes iptables rules ahead of it,
# so a published container port stays open while ufw reports it blocked.
#
# The database VMs are NOT bootstrapped by this script — see README.md §2.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
# app = Traefik + tenant containers (pulls images)
# ci  = Actions runner + registry     (builds and serves them)
ROLE="${ROLE:-app}"
# Where zo-app-1 pulls from. Plain HTTP is acceptable only because this subnet
# is private and the registry is not routable from anywhere else.
REGISTRY_HOST="${REGISTRY_HOST:-10.10.0.210:${REGISTRY_PORT}}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
case "$ROLE" in app|ci) ;; *) echo "ROLE must be app or ci" >&2; exit 1 ;; esac
log "Role: ${ROLE}"

log "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg jq git unattended-upgrades

log "Docker"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

log "Docker daemon config"
# Container logs are unbounded by default and will fill the disk on a box that
# also stores image layers. On the app node, also authorise the CI node's
# plain-HTTP registry — Docker refuses a non-TLS registry unless told otherwise,
# and `localhost` is the only implicit exception.
if [ "$ROLE" = "app" ]; then
  cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "insecure-registries": ["${REGISTRY_HOST}"]
}
JSON
else
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
fi
systemctl restart docker

log "Deploy user: ${DEPLOY_USER}"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
# Ubuntu leaves root locked and Subiquity puts your key in the ADMIN user's home,
# so /root/.ssh/authorized_keys does not exist here. Reading only that path leaves
# the deploy user with no key at all — and the script still prints "Done".
# SUDO_USER is whoever invoked this through sudo; root is the fallback for the
# rare install where you really are root.
for src in "/home/${SUDO_USER:-root}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
  if [ -f "$src" ]; then
    install -m 0600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
      "$src" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    echo "    seeded ${DEPLOY_USER}'s authorized_keys from ${src}"
    break
  fi
done
[ -f "/home/${DEPLOY_USER}/.ssh/authorized_keys" ] \
  || echo "    WARNING: no authorized_keys found to copy — ${DEPLOY_USER} has no SSH access"

log "SSH hardening"
# Keys only. Do NOT lock yourself out: confirm you can log in as ${DEPLOY_USER}
# in a SECOND session before closing this one.
cat > /etc/ssh/sshd_config.d/99-zuloone.conf <<'CONF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
CONF
sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd

log "Unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

if [ "$ROLE" = "ci" ]; then
  log "Image registry on :${REGISTRY_PORT}"
  # Bound to all interfaces so zo-app-1 can pull across the app subnet. No TLS
  # and no auth: acceptable only because nothing NATs port 5000 from outside,
  # and both hosts on this subnet are ours. Revisit the moment either changes.
  # Delete must be enabled or the garbage collector can never reclaim space.
  if [ -z "$(docker ps -aq -f name='^zuloone-registry$')" ]; then
    docker volume create zuloone-registry-data >/dev/null
    docker run -d --name zuloone-registry --restart unless-stopped \
      -p "${REGISTRY_PORT}:5000" \
      -e REGISTRY_STORAGE_DELETE_ENABLED=true \
      -v zuloone-registry-data:/var/lib/registry \
      registry:2 >/dev/null
  fi
fi

log "Stack directory"
install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/zuloone
install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/zuloone/certs

if [ "$ROLE" = "ci" ]; then
  registry_line="registry    :${REGISTRY_PORT}  ($(docker inspect -f '{{.State.Status}}' zuloone-registry 2>/dev/null || echo '?'))"
  next_lines="  1. Install the GitHub Actions runner as ${DEPLOY_USER} (labels: self-hosted, linux, x64)
  2. Push a tag in zulo.one to build the first image"
else
  registry_line="registry    pulls from ${REGISTRY_HOST} (insecure-registries set)"
  next_lines="  1. Put origin.pem + origin.key in /opt/zuloone/certs
  2. Import mikrotik.rsc BEFORE starting the stack
  3. Copy prod/ to /opt/zuloone, fill .env, docker compose up -d"
fi

cat <<EOF

Done — role ${ROLE}.

  docker      $(docker --version | cut -d, -f1)
  ${registry_line}
  deploy user ${DEPLOY_USER}
  stack dir   /opt/zuloone   (certs/ is 0700)

NEXT:
${next_lines}

VERIFY SSH IN A SECOND SESSION before closing this one — password auth is now off.
EOF
