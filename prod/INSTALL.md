# INSTALL — building the infrastructure from zero

Everything below assumes ESXi, the three subnets and the MikroTik routers are already
working. This document only builds the virtual machines, the database cluster, the
container host, CI, and the Cloudflare configuration.

Read [ARCHITECTURE.md](ARCHITECTURE.md) first for *why* things are placed where they are.
This file is the *how*, in order, with a checkpoint after every phase.

---

## Phase 0 — Before you start

### 0.1 Access checklist

| You need | Used in |
|---|---|
| vCenter, permission to create VMs on all three hosts | Phase 1 |
| Ubuntu Server 26.04 LTS ISO uploaded to a datastore | Phase 1 |
| MikroTik admin (Winbox or SSH) | Phase 6 |
| Cloudflare account, and control of the registrar for `zulo.one` (delegation happens in §7.0) | Phase 7 |
| GitHub access to `getzulo` (runner registration token) | Phase 8 |
| An SSH public key on your workstation | Phase 2 |
| Somewhere off-site for backups (second machine or storage box) | Phase 4 |

### 0.2 Why the two database nodes are in different subnets

Subnets are bound to hosts — one subnet per ESXi host. So putting both database nodes in
the same subnet would land them on the **same physical machine**, and one dead host would
take the primary and the standby together, which defeats the entire point of replicating
them.

That is why `zo-pg-1` sits at **10.10.1.210** and `zo-pg-2` at **10.10.2.210**: different
subnets means different hosts, and the standby genuinely survives losing the primary's
hardware. Local disks help too — there is no shared array whose failure would take both.

**The cost, stated plainly.** `zo-pg-1` shares the app segment with `zo-app-1`. Traffic
from that segment to 5432 **never reaches the router**, so the MikroTik cannot filter it —
`pg_hba.conf` and role permissions are the only controls on that path. Container traffic
is still governed, because `container-egress.sh` runs on the host itself (Phase 5.3).

The CI runner used to sit on that segment too, which was the sharper edge of this: it
executes whatever is in the repository. Moving it to the core subnet (10.10.0.210) took
that away — it now reaches nothing in the app or data tiers except through the router.

The remaining consequence of that move: **image pulls now cross the router**, so
`zo-app-1` needs an explicit rule to reach the registry (Phase 6.3). Without it the
tenant cannot start and the error is a plain pull timeout.

### 0.3 Machine plan

| VM | Host / subnet | IP | vCPU | RAM | Disk | Purpose |
|---|---|---|---|---|---|---|
| `zo-pg-1` | app · 10.10.1.0/24 | 10.10.1.210 | 4 | 8 GB | 200 GB | Postgres + Patroni + etcd — see §0.2 |
| `zo-pg-2` | data · 10.10.2.0/24 | 10.10.2.210 | 2 | 6 GB | 250 GB | Postgres + Patroni + etcd + pgBackRest repo |
| `zo-app-1` | app · 10.10.1.0/24 | 10.10.1.220 | 4 | 8 GB | 120 GB | Docker: Traefik + tenant containers |
| `zo-ci-1` | **core** · 10.10.0.0/24 | 10.10.0.210 | 4 | 8 GB | 150 GB | Actions runner, builds, image registry |
| `zo-pgw-1` | core · 10.10.0.0/24 | 10.10.0.220 | 1 | 1 GB | 20 GB | **etcd voter only** — no PostgreSQL (§3.2) |
| `zo-cp-1` | core · 10.10.0.0/24 | 10.10.0.200 | 2 | 2 GB | 40 GB | Control plane — **build last**, see Phase 10 |

**No gateway VM.** The MikroTik already routes and NATs. A small bastion in the core
subnet is worth considering later so SSH is never exposed from the app and data tiers,
but it is not needed to get running.

There is no shared storage, so there is no vMotion and no vSphere HA. That is fine —
nothing here depends on them, and local disks are better for Postgres anyway.

---

## Phase 1 — Create and install the VMs

Five VMs, installed by hand. Repeat this phase once per machine, using the row from
§0.3 each time. `zo-cp-1` is not built yet — see Phase 10.

> Phase 3 also talks about a replica "cloning" itself. That is Patroni copying the
> leader's data directory to bootstrap replication — nothing to do with virtual machines.

### 1.1 Create the VM in vCenter

New VM → **Guest OS Family: Linux · Version: Ubuntu Linux (64-bit)**, on the host that
carries the right subnet, attached to that subnet's port group.

Set vCPU / RAM / disk from §0.3. Two defaults are wrong and both matter:

| Setting | Change to | Why |
|---|---|---|
| SCSI controller | **VMware Paravirtual** | Substantially better I/O than LSI Logic; the driver is in the Ubuntu installer |
| Network adapter | **VMXNET3** | E1000 is emulated and burns CPU under load |

Attach the Ubuntu Server 26.04 LTS ISO and power on.

### 1.2 Install Ubuntu Server

Ubuntu's installer (Subiquity) differs from Debian's in four places that matter here.
Everything not mentioned can take its default.

**Network — Edit IPv4 → Manual.** Do it here so the machine is right from first boot:

| Field | `zo-pg-1` |
|---|---|
| Subnet | `10.10.1.0/24` |
| Address | `10.10.1.210` |
| Gateway | `10.10.1.1` |
| Name servers | `10.10.2.10` |

The gateway is the `.1` of the VM's **own** subnet, and the name server is **not** the
gateway — they are different addresses in different subnets. Per-machine values are in
the table below.

**Storage — turn LVM off.** "Use an entire disk" defaults to setting up an LVM group,
and Subiquity then creates a root logical volume that does **not** consume the whole
disk. On a 200 GB database volume you would quietly get a fraction of it, and discover
this when WAL fills the filesystem. Uncheck *"Set up this disk as an LVM group"*.

If you would rather keep LVM, expand it after install instead:
`sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv`

**Profile** — hostname `zo-pg-1`. Create your admin user here; Ubuntu leaves the **root
account locked**, so this user plus `sudo` is how you get in. There is no root SSH login
to fall back on.

**SSH** — tick *"Install OpenSSH server"*. If your public key is on GitHub, the
*"Import SSH identity"* option puts it on the machine during install and saves the
`ssh-copy-id` step entirely.

Skip the "Featured server snaps" screen — select nothing.

### 1.3 After first boot

**Check whether cloud-init owns the network.** Ubuntu Server ships cloud-init, and where
it manages netplan it regenerates the configuration on boot and can quietly undo your
addressing. On a **manual ISO install** it usually does not: Subiquity writes
`/etc/netplan/00-installer-config.yaml` and cloud-init's units end up inactive.

```bash
ls /etc/netplan/                              # 00-installer-config.yaml → Subiquity owns it
systemctl is-enabled cloud-init 2>&1          # "not-found" → nothing to disable
```

Only if you see `50-cloud-init.yaml`, or the service is enabled, pin it:

```bash
sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
```

(Verified on this build: cloud-init 26.1 installed, units `not-found`, addressing
survived a reboot untouched without the override.)

Then the packages and the check:

```bash
sudo apt-get update && sudo apt-get -y upgrade
```

Copy the helper over and run it — it installs what every node needs and verifies the
machine against §0.3:

```bash
scp prod/first-boot.sh <you>@10.10.1.210:/tmp/           # from your workstation
ssh <you>@10.10.1.210 'sudo bash /tmp/first-boot.sh'
```

It checks address, netmask, gateway, resolver and inter-tier reachability, and exits
non-zero listing whatever is wrong. **A wrong gateway is the one worth catching here** —
the VM boots perfectly, looks healthy, and only fails in Phase 3 when the standby cannot
reach the primary, where it presents as a Postgres problem rather than a network one.

Network settings live in `/etc/netplan/*.yaml`. To change an address later:

```yaml
# /etc/netplan/00-installer-config.yaml   (chmod 600, or netplan warns)
network:
  version: 2
  ethernets:
    ens192:                      # confirm with: ip -br link
      addresses: [10.10.1.210/24]
      routes:
        - to: default
          via: 10.10.1.1
      nameservers:
        addresses: [10.10.2.10]
```

```bash
sudo netplan try        # applies with an automatic rollback if you lose the session
sudo netplan apply
```

`netplan try` is worth the habit: it reverts after 120 seconds unless you confirm, so a
mistake on a remote machine does not strand you.

> **Checkpoint 1** — four VMs plus the witness, each on the intended host and port
> group, each with its own static address, each able to reach its gateway.

---

## Phase 2 — SSH access

Skip this if you used *"Import SSH identity"* during the install — the key is already
there. Otherwise, from your workstation, for each VM:

```bash
ssh-copy-id <you>@10.10.1.210
ssh <you>@10.10.1.210 'echo ok'      # must succeed WITHOUT a password prompt
```

Note there is no `root@` here: Ubuntu leaves the root account locked, so everything
below runs as your admin user through `sudo`. That is also why `bootstrap.sh` is invoked
with `sudo bash -s` rather than as root directly.

**Do not disable password authentication yet.** `bootstrap.sh` does that in Phase 5, and
only after copying your key to the `deploy` user. Turning it off now on a machine where
the key did not actually land means recovering through the vCenter console.

> **Checkpoint 2** — key-based SSH works into all of them.

---

## Phase 3 — Postgres cluster with Patroni

Two data nodes that arbitrate leadership between themselves through etcd. No operator
action on failover, and none on recovery either: a returned ex-leader rewinds itself and
comes back as a replica.

Build it while the cluster is empty. Rehearsing a failover on empty data costs nothing.

> **Patroni owns Postgres from here on.** Never `systemctl start postgresql` or
> `pg_ctlcluster` on the data nodes again — Patroni starts and stops the server itself,
> and a manual start races it. `start.conf` stays `manual` for exactly this reason.

### 3.1 PostgreSQL on the two data nodes

```bash
sudo apt-get install -y postgresql-common ca-certificates
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh   # answer Y
sudo apt-get install -y postgresql-17 pgbackrest
```

PGDG's bootstrap script derives the codename from `/etc/os-release`, so there is nothing
to mistype. Ubuntu 26.04 is `resolute`, and PGDG builds for it.

**Pin the major version.** The bare `postgresql` metapackage follows whatever is newest,
and a major-version jump leaves a data directory the new server refuses to open.

Then hand the server over to Patroni and wipe what the package created — Patroni does its
own `initdb`:

```bash
echo manual | sudo tee /etc/postgresql/17/main/start.conf
sudo systemctl daemon-reload
sudo pg_ctlcluster 17 main stop 2>/dev/null
sudo -u postgres bash -c 'rm -rf /var/lib/postgresql/17/main/*'
```

`zo-pgw-1` needs **no PostgreSQL at all** — it exists only to be the third etcd vote.

### 3.2 etcd on all three nodes

```bash
sudo apt-get install -y etcd-server etcd-client
```

Three nodes, because a quorum of two is not a quorum. `zo-pgw-1` is the third vote and
sits on the core ESXi host — neither of the machines carrying data — so it stays
reachable exactly when its opinion matters.

**Configure through `ETCD_*` variables, never `DAEMON_ARGS`.** The packaged unit already
exports `ETCD_NAME` and `ETCD_DATA_DIR`, and etcd refuses to start when a setting arrives
as both an environment variable and a flag:

```
conflicting environment variable is shadowed by corresponding command-line flag
```

On each node, substituting its own name and address:

```bash
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd/*          # the install starts a single-node etcd; it would conflict

sudo tee /etc/default/etcd <<'EOF'
ETCD_NAME=zo-pg-1
ETCD_DATA_DIR=/var/lib/etcd/default
ETCD_LISTEN_PEER_URLS=http://10.10.1.210:2380
ETCD_LISTEN_CLIENT_URLS=http://10.10.1.210:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://10.10.1.210:2380
ETCD_ADVERTISE_CLIENT_URLS=http://10.10.1.210:2379
ETCD_INITIAL_CLUSTER=zo-pg-1=http://10.10.1.210:2380,zo-pg-2=http://10.10.2.210:2380,zo-pgw-1=http://10.10.0.220:2380
ETCD_INITIAL_CLUSTER_TOKEN=zuloone
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_ENABLE_V2=false
EOF
```

Start all three **together** — they form the cluster by finding each other, and one
started alone will time out waiting:

```bash
sudo systemctl enable --now etcd     # on all three, close together
sudo etcdctl --endpoints=http://10.10.1.210:2379 endpoint status --cluster -w table
```

Expect three rows, one with `IS LEADER: true`.

The nodes are in three different subnets, so **etcd traffic crosses the router** —
2379 and 2380 between all three. Those rules are in `mikrotik.rsc`; without them the
cluster never forms.

### 3.3 Patroni on the two data nodes

```bash
sudo apt-get install -y patroni python3-etcd
```

**`python3-etcd`, not `python3-etcd3`.** Patroni's etcd driver is built on the former;
with the wrong one it starts and reports:

```
Can not find suitable configuration of distributed configuration store
Available implementations: consul, kubernetes
```

Consul is not packaged for Ubuntu 26.04, so etcd is the only route.

The packaged unit hard-codes the path via `ConditionPathExists`, so the file must be
`/etc/patroni/config.yml` — any other name and the service silently does nothing.

```yaml
scope: zuloone
name: zo-pg-1                         # this node

restapi:
  listen: 10.10.1.210:8008
  connect_address: 10.10.1.210:8008

etcd3:
  hosts: 10.10.1.210:2379,10.10.2.210:2379,10.10.0.220:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      # The reason this cluster exists: a returned ex-leader rewinds itself back in
      # rather than waiting for an operator.
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"           # required for pg_rewind
        max_wal_senders: 10
        max_replication_slots: 10
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 10.10.1.210:5432
  connect_address: 10.10.1.210:5432
  data_dir: /var/lib/postgresql/17/main
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    replication: {username: replicator, password: 'CHANGE_ME'}
    superuser:   {username: postgres,   password: 'CHANGE_ME'}
  parameters:
    shared_buffers: 2GB               # 1536MB on zo-pg-2, which has 6 GB
    effective_cache_size: 6GB         # 4GB on zo-pg-2
    max_connections: 200
  pg_hba:
    - local all all peer
    - host all all 127.0.0.1/32 scram-sha-256
    # EVERY subnet the nodes live in. They are deliberately spread across three,
    # and a single /24 here leaves a node unable to authenticate to its OWN
    # Postgres — which presents as a blank timeline and no promotion, not as an
    # authentication error.
    - host all all 10.10.0.0/24 scram-sha-256
    - host all all 10.10.1.0/24 scram-sha-256
    - host all all 10.10.2.0/24 scram-sha-256
    - host replication replicator 10.10.1.210/32 scram-sha-256
    - host replication replicator 10.10.2.210/32 scram-sha-256
```

`chown postgres:postgres` and `chmod 600` it — it carries two passwords.

Start the **leader first** and let it bootstrap, then the second node, which clones
itself:

```bash
sudo systemctl enable --now patroni          # zo-pg-1 first
sudo patronictl -c /etc/patroni/config.yml list
sudo systemctl enable --now patroni          # then zo-pg-2
```

> **Checkpoint 3** — `patronictl list` shows one `Leader` and one `Replica` with State
> `streaming`, Lag 0, both on the same timeline.

### 3.4 Rehearse it — the whole point is that you do nothing

```bash
sudo systemctl stop patroni                  # on the leader
```

Watch the other node. Measured on this cluster: **promoted in 12 seconds**, unattended.

Now bring the dead node back — and issue **no other command**:

```bash
sudo systemctl start patroni                 # on the ex-leader
```

Measured: **rejoined as a replica in 10 seconds**, having run `pg_rewind` on its own.
Also verified across a full reboot: the node came back, worked out that the leader key
in etcd belonged to someone else, and demoted itself without help.

**Roles stay swapped, and that is correct.** There is no failing back. If you do want the
leader on a specific node — better hardware, say — that is a deliberate maintenance
action:

```bash
sudo patronictl -c /etc/patroni/config.yml switchover
```

Which waits for the replica to catch up first, so it costs seconds rather than the
failover's dozen.

---

## Phase 4 — Backups

Replication covers a node dying. It does **not** cover a bad migration or an accidental
`DELETE` — those replicate to the standby faithfully and instantly. This phase is what
recovers from them, and they are likelier than hardware failure.

The repository lives on `zo-pg-2`, which is also a cluster member. That coupling is
deliberate (no spare machine) and it has a cost: if `zo-pg-2` is down while `zo-pg-1`
leads, nothing can be archived. §4.2 bounds the damage.

### 4.1 SSH between the postgres accounts

pgBackRest moves files over SSH, so the two `postgres` accounts must trust each other —
both directions, because either node can end up leading.

```bash
# on each data node
sudo install -d -m 700 -o postgres -g postgres /var/lib/postgresql/.ssh
sudo -u postgres ssh-keygen -t ed25519 -N '' -f /var/lib/postgresql/.ssh/id_ed25519 -q
```

Append each node's `id_ed25519.pub` to the other's
`/var/lib/postgresql/.ssh/authorized_keys` (mode 600, owned by postgres), then pin the
host keys so the first unattended run is not blocked on a prompt:

```bash
sudo -u postgres bash -c 'ssh-keyscan -H <other-node-ip> >> /var/lib/postgresql/.ssh/known_hosts'
sudo -u postgres ssh -o BatchMode=yes postgres@<other-node-ip> hostname   # must print it
```

> Use **absolute paths**, not `~`. In `sudo -u postgres cat ~/.ssh/id_ed25519.pub` the
> tilde is expanded by *your* shell before sudo runs, so it reads your home directory
> and fails with a permission error that looks like a postgres problem.

### 4.2 pgBackRest

The Debian package ships **`/etc/pgbackrest.conf`**, not `/etc/pgbackrest/pgbackrest.conf`.
pgBackRest prefers the directory form when it exists, so creating one leaves the file you
just edited being ignored. Edit the file the package installed.

On `zo-pg-2` (repository **and** cluster member):

```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=4
repo1-retention-diff=6
repo1-bundle=y
repo1-block=y
start-fast=y
backup-standby=prefer
archive-push-queue-max=32GiB
process-max=2
log-level-file=detail

# INDEX ORDER IS LOAD-BEARING — see the warning below.
[zuloone]
pg1-path=/var/lib/postgresql/17/main
pg2-path=/var/lib/postgresql/17/main
pg2-host=10.10.1.210
pg2-host-user=postgres
```

On `zo-pg-1` (cluster member only — it knows nothing but itself):

```ini
[global]
repo1-host=10.10.2.210
repo1-host-user=postgres
archive-push-queue-max=32GiB
log-level-file=detail

[zuloone]
pg1-path=/var/lib/postgresql/17/main
```

> **`pg1` must be the LOCAL cluster on the repository host.** Put the remote node at
> `pg1` and `backup` and `check` still pass — they iterate every `pgN` — but
> `archive-push` only ever looks at `pg1`, finds a host there, and refuses:
>
> ```
> ERROR: [072]: archive-push command must be run on the PostgreSQL host
> ```
>
> Nothing surfaces until this node is elected leader, so the mistake tests perfectly
> clean and breaks at the first failover, with the backup you would then need.

**`archive-push-queue-max`** is a deliberate trade. If the repository host is
unreachable, WAL accumulates in `pg_wal` until the partition fills and Postgres stops
hard. Past this bound `archive-push` reports success *without* archiving: the database
stays up and PITR continuity breaks instead. That is only a safe trade because §4.5
notices within five minutes — without the monitor it is a silent data-loss window.

Roles are **not** encoded anywhere above. pgBackRest asks the cluster who is leading at
run time, so a failover needs no edit here.

### 4.3 archive_command belongs in the DCS, not in a file

Patroni owns `postgresql.conf` and rewrites it. Setting `archive_command` on one host
means the *other* host has no idea, and archiving stops the moment roles swap. Set it
once, cluster-wide:

```bash
sudo -u postgres patronictl -c /etc/patroni/config.yml edit-config --force \
  -p archive_mode=on \
  -p 'archive_command=pgbackrest --stanza=zuloone archive-push %p' \
  -p archive_timeout=60s
```

`archive_mode=on`, never `always`: only the leader ships WAL. A standby archiving the
same segments races the leader into the same repository.

`archive_timeout=60s` bounds how much WAL an idle cluster can lose — without it a quiet
Sunday leaves the last partial segment unarchived indefinitely.

`archive_mode` needs a **restart** (`archive_command` and `archive_timeout` do not).
Patroni will show `Pending restart` with the reason. Replica first, then the leader:

```bash
sudo -u postgres patronictl -c /etc/patroni/config.yml restart zuloone zo-pg-2 --force
sudo -u postgres patronictl -c /etc/patroni/config.yml restart zuloone zo-pg-1 --force
```

Then, on the repository host:

```bash
sudo -u postgres pgbackrest --stanza=zuloone stanza-create
sudo -u postgres pgbackrest --stanza=zuloone --log-level-console=info check
sudo -u postgres pgbackrest --stanza=zuloone --type=full backup
```

**Read the output of `check`.** It is the only step that proves `archive_command`
actually delivers. Look for the line naming a segment — `check repo1 archive for WAL
(primary)` followed by `successfully archived`. If instead you see

```
INFO: switch wal not performed because this is a standby
```

the check verified that the repository is reachable and **nothing else**. It still exits
0. See §4.5.

### 4.4 Schedule

Timers go on the **repository host**, not on "the primary" — there is no fixed primary.

```bash
# /etc/systemd/system/pgbackrest-{full,diff}.service   Type=oneshot, User=postgres
#   ExecStart=/usr/bin/pgbackrest --stanza=zuloone --type={full,diff} backup
# /etc/systemd/system/pgbackrest-full.timer   OnCalendar=Sun *-*-* 01:00:00
# /etc/systemd/system/pgbackrest-diff.timer   OnCalendar=Mon..Sat *-*-* 01:00:00
# both: RandomizedDelaySec=10m, Persistent=true
systemctl enable --now pgbackrest-full.timer pgbackrest-diff.timer
```

`Persistent=true` re-runs a backup missed while the machine was down rather than skipping
the week silently.

With `backup-standby=prefer` the copy is read from whichever node is following, so the
leader carries no backup I/O. `prefer`, not `y`: if the standby is gone, back up from the
leader instead of not backing up at all.

### 4.5 Watch it, because it fails quietly

On **both** database nodes:

```bash
sudo ./check-cluster.sh --install     # runs every 5 minutes via a systemd timer
sudo ./check-cluster.sh               # run once, read the output
journalctl -u zuloone-cluster-check   # history
```

It checks what looks fine until you need it: etcd quorum lost (Patroni then refuses to
promote anyone), a standby that stopped following, an archiver whose last attempt failed,
WAL piling up unarchived, a backup that aged out, the data partition filling.

It reports the archiver from `pg_stat_archiver` **directly**, because `pgbackrest check`
is not always meaningful. On a node whose config lists only itself, running as a standby,
there is no primary to test — check exits 0 having verified nothing. The script says which
of the two happened rather than printing "passes" for both. Note `failed_count` alone
proves nothing: it is a lifetime counter, so what matters is whether `last_failed_time` is
newer than `last_archived_time`.

Set `ALERT_CMD` in the unit to pipe the report somewhere. Without it the script is silent
apart from its exit code, which is what an external monitor should key on anyway.

### 4.6 Prove a restore — a backup you have not restored is a hypothesis

Restore into a scratch directory on the repository host. **Point `pg1-path` at the
restore target through a config of its own**, so a typo cannot resolve to the live data
directory — `restore` empties whatever it is aimed at.

```bash
cat > /var/lib/postgresql/rt.conf <<'EOF'
[global]
repo1-path=/var/lib/pgbackrest
[zuloone]
pg1-path=/var/lib/postgresql/restore-test
EOF
sudo install -d -m 700 -o postgres -g postgres /var/lib/postgresql/restore-test
sudo -u postgres pgbackrest --config=/var/lib/postgresql/rt.conf --stanza=zuloone \
     --archive-mode=off --log-level-console=info restore
```

`--archive-mode=off` is **not** optional. The restored copy promotes onto a new timeline;
if it could archive, it would push a timeline-history file the real cluster is about to
claim for itself, and the collision would surface at some future failover. Verify
afterwards that it did not:

```bash
sudo ls /var/lib/pgbackrest/archive/zuloone/17-1/     # no timeline the live cluster lacks
```

Then start it on a spare port and look at the data:

```bash
printf 'port = 5433\narchive_mode = off\nlisten_addresses = %s\n' "'localhost'" \
  | sudo tee -a /var/lib/postgresql/restore-test/postgresql.auto.conf
sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl -D /var/lib/postgresql/restore-test \
     -l /var/lib/postgresql/restore-test/startup.log -w start
sudo -u postgres psql -p 5433 -c 'SELECT ...'
```

The recovery log should show `restored log file ... from archive` for segments *after*
the backup. That is what proves the WAL archive works, not just the base backup. Verify a
row written **after** the full backup is present — restoring only what the backup already
contained proves half the system.

Tear down when done (`pg_ctl -m immediate stop`, then remove the directory and config).

For a real point-in-time recovery, add a target:

```bash
--type=time --target='2026-09-07 12:00:00' --target-action=promote
```

### 4.7 Off-site, and the witness

The off-site copy is what survives losing the site. Over WireGuard, mirror the repository
to the second machine.

Quorum is **not** here — it is the etcd cluster on the LAN (§3.2). A leader election has
to resolve in milliseconds, which a tunnel cannot promise.

> **Checkpoint 4** — `check` reports a *successfully archived* segment (not the standby
> skip), one full backup exists, both nodes report healthy, and you have restored into a
> scratch instance and seen a post-backup row come back.
>
> Then do it once more **after a switchover**, with the repository host leading. That is
> the configuration §4.2 warns about, it is the one that breaks, and it is invisible from
> the state you just tested. Put the drill on the calendar quarterly.

---

## Phase 5 — App and CI hosts

### 5.1 Get the files onto the machines

From your workstation:

```bash
scp -r prod <you>@10.10.1.220:/tmp/     # zo-app-1
scp -r prod <you>@10.10.0.210:/tmp/     # zo-ci-1
```

(`git clone` also works, but `zulo-deployment` is private, so that means putting a
token on the VM. `scp` avoids the credential entirely.)

### 5.2 Bootstrap

**The `ROLE=ci` on the second line is not optional** — it is what starts the registry
and skips the app-only Docker configuration:

```bash
ssh <you>@10.10.1.220 'sudo bash -s' < prod/bootstrap.sh           # zo-app-1
ssh <you>@10.10.0.210 'sudo ROLE=ci bash -s' < prod/bootstrap.sh   # zo-ci-1
```

Both get Docker, a `deploy` user, capped container logs, and SSH password auth off.
`zo-ci-1` also runs the image registry on `:5000`; `zo-app-1` also gets
`10.10.0.210:5000` into `insecure-registries`, without which Docker refuses to pull from
a non-TLS registry.

**Open a second session and confirm you can log in as `deploy` before closing the
first.** Password authentication is off after this runs.

### 5.3 Lock the containers in — before any tenant starts

```bash
ssh <you>@10.10.1.220
cd /tmp/prod && sudo ./container-egress.sh --install
```

Tenants get Postgres on 5432 and nothing else: not the rest of the LAN, not the
unrelated machines on it, not the internet.

This has to happen on the host. The router cannot do it — container traffic leaves the
VM NAT'd behind `10.10.1.220`, so the MikroTik cannot tell it from the VM's own, and
traffic to anything else in `10.10.1.0/24` never reaches the router at all because it
is switched. `ufw` cannot do it either: Docker writes its rules into `FORWARD` ahead of
ufw's, so `ufw deny` leaves container traffic flowing while reporting the port blocked.

> **Checkpoint 5** — `docker info` works on both as `deploy`;
> `curl http://10.10.0.210:5000/v2/` from `zo-app-1` returns `{}`;
> `./container-egress.sh --status` reports `database nodes allowed: 2/2` and lists a
> populated `ZULOONE-HOST-IN` chain. Both matter: a `MISMATCH` line means only one
> database node is permitted and tenants will lose the database at the next failover,
> and a missing host chain means containers can still reach every service on this VM.

---

## Phase 6 — MikroTik

Your routers already work; this only adds the rules this project needs.

### 6.1 Edit and import

`prod/mikrotik.rsc` already uses `10.10.1.220` for the tenant host. Read §1.1 of that
file first — this network is **three** routers, not one, and each section belongs on a
specific device. Confirm the WAN
interface list matches your setup, then import. It creates:

- a `cloudflare` address list — 15 IPv4 prefixes
- destination NAT for 80/443 to `zo-app-1`, **only when the source is in that list**
- a forward guard as a second layer
- the inter-tier matrix: app reaches data on 5432, nothing else crosses

### 6.2 Why the source restriction is load-bearing

The tenant runs with `ZuloOne__BehindReverseProxy=true`, which enables forwarded
headers with `KnownNetworks` and `KnownProxies` **cleared** — Core trusts
`X-Forwarded-For` from whoever connects. Correct behind a proxy, dangerous in front of
one: anyone who can reach the origin directly can forge client IPs and bypass every
Cloudflare rule you write.

### 6.3 Replication between the database nodes

The two nodes are in different subnets, so replication crosses the router and needs
explicit rules in both directions — the direction reverses after a failover:

```
/ip firewall filter
add chain=forward action=accept protocol=tcp     src-address=10.10.2.210 dst-address=10.10.1.210 dst-port=5432     comment="patroni: replication pg-2 -> pg-1"
add chain=forward action=accept protocol=tcp     src-address=10.10.1.210 dst-address=10.10.2.210 dst-port=5432     comment="patroni: replication pg-1 -> pg-2"
# etcd: peer 2380 and client 2379 between ALL THREE nodes, which sit in three
# different subnets — without these the cluster never forms and Patroni never starts.
add chain=forward action=accept protocol=tcp     src-address=10.10.1.210,10.10.2.210,10.10.0.220     dst-address=10.10.1.210,10.10.2.210,10.10.0.220 dst-port=2379,2380     comment="etcd: peer + client"
```

The app tier reaches `zo-pg-1` without touching the router at all — same subnet, switched.
It reaches `zo-pg-2` through the existing app→data rule, which matters because the tenant
must be able to follow a failover onto it.

> **Checkpoint 6** — from outside your network,
> `curl -m 5 -sk https://<public-ip>/health` must **time out**. If it answers,
> `X-Forwarded-For` is forgeable and the lockdown has failed. Stop and fix it.

---

## Phase 7 — Cloudflare

### 7.0 Delegate the domain first

Everything below assumes Cloudflare is authoritative for `zulo.one`. Check before you
start, because every other step silently does nothing until this is true:

```bash
dig +short NS zulo.one          # must answer *.ns.cloudflare.com
```

If it answers something else — `domaincontrol.com` is GoDaddy, `awsdns` is Route 53 —
then: **Cloudflare → Add a site → `zulo.one` → Free**, copy the two nameservers it
assigns, and replace the nameservers at the registrar. Propagation is usually an hour or
two and can take a day; Cloudflare e-mails when it completes.

`getzulo.com` is a separate matter and does **not** belong on this origin. It is a
marketing and documentation site: put it on Cloudflare Pages, where it costs nothing,
needs no origin certificate, and — the actual reason — keeps a public static site off
the machine that runs customer databases.

### 7.1 DNS

**DNS → Records → Add record**

| Type | Name | Content | Proxy |
|---|---|---|---|
| `A` | `*` | your public IP | **Proxied** |
| `A` | `@` | `192.0.2.1` | **Proxied** |
| `A` | `www` | `192.0.2.1` | **Proxied** |

The wildcard is what makes a new tenant need no DNS change at all. Wildcards can be
proxied on **every** Cloudflare plan. Do **not** add per-tenant records; that
reintroduces exactly the manual step the wildcard removes.

`192.0.2.1` is TEST-NET-1 and is not routable anywhere. Paired with a **Rules →
Redirect Rule** sending `zulo.one` and `www.zulo.one` to the marketing site, the
redirect is answered at Cloudflare's edge and never reaches your origin. Point the apex
at the real IP instead and it lands on Traefik, which has no router for it and answers
404 — a poor greeting for the name people type by hand.

**Proxy must be on for all of them.** Grey-cloud any one and it publishes your origin
IP, at which point the whole Cloudflare-only restriction on the router is decoration.

Note what the wildcard does NOT do: it answers for *every* name, so
`whatever.zulo.one` resolves whether or not that tenant exists, and Traefik returns 404
rather than DNS returning NXDOMAIN. That is fine — but it means DNS reserves nothing.

### 7.1.1 Reserved names are enforced in code, not here

There is no way to exempt a name from a wildcard. If a customer can choose their own
slug, then without a check they can choose `admin` and take `admin.zulo.one`, or `cp`
and take the control plane's own address.

That check lives in `ZuloOne.ControlPlane.Provisioning.ReservedSlugs` — 143 names
covering infrastructure, resolver and mail conventions, environment names, brand terms,
anything resembling authentication or payment, and the RFC 2142 abuse addresses. It also
refuses the `xn--` punycode prefix outright, because `xn--dmin-7na` passes any ASCII
slug pattern and renders as "аdmin" with a Cyrillic а.

To add names without cutting a release, extend `Fleet:AdditionalReservedSlugs` in the
control plane's configuration. That list can only **add** — the compiled-in baseline is
not shortenable from configuration, so a mistyped section cannot give away `admin`.

### 7.2 Encryption mode — get this one right

**SSL/TLS → Overview → Full (Strict)**

This is not a preference:

- **Flexible** — Cloudflare talks plain HTTP to the origin, Traefik answers with a
  redirect to HTTPS, the browser returns through Cloudflare on :80, and you have an
  infinite redirect loop.
- **Full** — encrypted but validates nothing, so it accepts any certificate including
  an attacker's.
- **Full (Strict)** — encrypted and validated. Cloudflare trusts its own Origin CA, so
  the certificate from §7.3 satisfies it.

Universal SSL covers `zulo.one` and `*.zulo.one` — the apex and **one** label. A
name like `a.b.zulo.one` gets no certificate from it.

### 7.3 Origin certificate

**SSL/TLS → Origin Server → Create Certificate**

- Private key type: RSA (2048)
- Hostnames: `zulo.one` **and** `*.zulo.one`
- Validity: 15 years

You are shown the certificate and the key **once**. Put them on `zo-app-1`:

```bash
# on zo-app-1, as deploy
install -d -m 0700 /opt/zuloone/certs
$EDITOR /opt/zuloone/certs/origin.pem     # paste the certificate
$EDITOR /opt/zuloone/certs/origin.key     # paste the private key
chmod 600 /opt/zuloone/certs/origin.key
```

One wildcard certificate covers every current and future tenant, so adding a tenant
needs no certificate work either. There is no ACME anywhere in this deployment.

### 7.4 WebSockets

**Network → WebSockets → On.** It is on by default on every plan, but SignalR depends
on it, so confirm rather than assume.

### 7.5 What you are NOT doing

- No per-tenant DNS records
- No ACME, no DNS-01, no API token in Traefik
- No page rules or Workers

> **Checkpoint 7** — `dig t1.zulo.one` returns a Cloudflare address, not your public IP.
> If it returns your IP, the record is DNS-only (grey cloud) and the origin is exposed.

---

## Phase 8 — CI runner and the first image

On `zo-ci-1`, as `deploy`: GitHub → `getzulo/zulo.one` → Settings → Actions → Runners →
**New self-hosted runner (Linux x64)**. Follow the commands shown, then install it as a
service:

```bash
./svc.sh install && ./svc.sh start
```

Labels must include `self-hosted`, `linux`, `x64` to match `runs-on` in the workflow.

The runner is in the `docker` group, which is root-equivalent on this VM. The workflow
already refuses to run on pull requests from forks; keep that guard.

Then cut the first release from your workstation:

```bash
cd zulo.one
git tag v2026.9.0 && git push origin v2026.9.0
```

Tag shape is enforced: `vYYYY.M.P`, no leading zeros, no prerelease suffix. The workflow
explains why if you get it wrong — the short version is that `Program.cs` reads
AssemblyVersion, which silently drops both.

> **Checkpoint 8** — `curl http://10.10.0.210:5000/v2/zuloone-core/tags/list` from
> `zo-app-1` lists `2026.9.0`.

---

## Phase 9 — Deploy the first tenant

```bash
# on zo-app-1, as deploy
cp -r /root/prod/* /opt/zuloone/ && cd /opt/zuloone
cp .env.example .env && chmod 600 .env && $EDITOR .env
```

`PG_HOSTS` lists **both** database nodes. The container works out which one is the
primary on its own — Npgsql probes `pg_is_in_recovery()` and re-checks every 10 seconds,
so it follows a failover with no VIP, no HAProxy and no action from you. It does not
retry a command that was already in flight, so expect a restart and a blip of tens of
seconds rather than a seamless switch.

Fill in: `ZULOONE_IMAGE=10.10.0.210:5000/zuloone-core:2026.9.0`, `T1_HOST=t1.zulo.one`,
`PG_HOSTS`, `PG_SSL_MODE` (check `SHOW ssl;` on the primary — never `Prefer`, it falls
back to plaintext silently), the database credentials, and a `T1_JWT_KEY` from
`openssl rand -base64 36`.

```bash
docker compose up -d
docker compose logs -f tenant-t1
```

First boot runs EF migrations → schema sync → metadata compile before Kestrel binds.
Against a warm LAN database this took about 10 seconds in testing.

Seed the administrator — one-shot, refuses once any user exists:

```bash
curl -fsS https://t1.zulo.one/api/auth/setup \
  -H 'Content-Type: application/json' \
  -d '{"name":"admin","email":"you@example.com","password":"<strong>"}'
```

### Verify

```bash
curl -fsS https://t1.zulo.one/health          # ready:true, version = the tag deployed
curl -fsS https://t1.zulo.one/ | head -5      # SPA index.html
curl -sk -o /dev/null -w '%{http_code}\n' https://t1.zulo.one/api/metadata/dictionaries
                                              # 401 — auth is enforced
curl -m 5 -sk https://<public-ip>/health      # must TIME OUT
```

And from inside the container — first succeeds, rest must **time out**:

```bash
c=$(docker ps -q -f name=tenant)
docker exec $c bash -c 'timeout 5 bash -c "</dev/tcp/10.10.1.210/5432" && echo PG-OK'
docker exec $c bash -c 'timeout 5 bash -c "</dev/tcp/10.10.0.210/5000" || echo BLOCKED'
docker exec $c bash -c 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"     || echo BLOCKED'
```

> **Checkpoint 9** — you can log in through a browser, and devtools → Network → WS
> shows `/hubs/zuloone` connected over WebSockets.

---

## Phase 10 — The control plane, later

`zo-cp-1` is deliberately last and should not be built yet. The control plane has **no
authentication of any kind** today, on an API that drops databases, holds a Postgres
admin connection, and stores every tenant's JWT signing key in plaintext. It also does
not currently serve its own dashboard.

The first tenants are provisioned by hand — Phase 9 is the whole procedure — and the
control plane starts earning its keep around the fifth. Sequence and required
configuration: [ARCHITECTURE.md §4](ARCHITECTURE.md).

---

## When the database fails — what to expect, what to do

Most of what used to be a procedure is now automatic. What remains is knowing what
"normal" looks like so you can tell when it is not.

### A node died

Nothing to do. The surviving node takes the leader key in etcd and promotes itself —
**12 seconds**, measured. The tenant's Npgsql pool re-probes `pg_is_in_recovery()`
within another 10 and reconnects. Requests in flight during the gap fail and the
container restarts; that is the expected blip, not a fault.

### A node came back

Start Patroni and stop there:

```bash
sudo systemctl start patroni
```

It reads the leader key, sees the job is taken, runs `pg_rewind` against the current
leader, and comes back as a replica — **10 seconds**, measured, including after a full
reboot. **Do not** start Postgres by hand, and do not try to "restore" the original
layout: roles stay swapped and the cluster is symmetric.

### Checking on it

```bash
sudo patronictl -c /etc/patroni/config.yml list
```

One `Leader`, one `Replica` with State `streaming` and Lag 0, both on the same timeline.
Anything else is worth reading the log for:

```bash
sudo journalctl -u patroni -n 50
```

### Nothing was promoted

The cluster **fails safe**: without an etcd quorum Patroni will not promote anyone,
because it cannot prove the old leader is gone. An outage, never a split brain.

| What you see | Cause |
|---|---|
| `patronictl list` errors on the DCS | etcd has lost quorum — two of three nodes must be up. Check `etcdctl endpoint status --cluster` |
| Replica present but State blank, timeline blank | Patroni cannot authenticate to its **own** Postgres — a subnet missing from `pg_hba` in the config |
| Patroni starts, then does nothing | Wrong etcd client library: it needs `python3-etcd`, not `python3-etcd3` |
| Service `active` but no cluster | Config is not at `/etc/patroni/config.yml`; the unit's `ConditionPathExists` is silent about it |

### Both nodes are gone

Restore from pgBackRest (§4.3) onto new hardware. The only case that costs hours rather
than seconds, and the reason the off-site copy exists.

## Troubleshooting, by symptom

| Symptom | Cause |
|---|---|
| Infinite redirect in the browser | Cloudflare mode is Flexible, not Full (Strict) — §7.2 |
| `525` or `526` from Cloudflare | Origin certificate missing, unreadable, or Traefik not serving it. Check `/opt/zuloone/certs` permissions |
| `521` from Cloudflare | Origin unreachable — MikroTik NAT rule, or Traefik not running |
| `502` from Traefik | Tenant container down, or the egress lockdown is missing its intra-bridge rule (rule 2) and killed the proxy hop |
| `404` on a hostname that should work | Traefik's docker provider sees no labels, or the router rule does not match `T1_HOST` |
| `/health` reports `1.0.0` | Image built without `--build-arg VERSION` |
| API returns 200 where 401 is expected | `CoreDevelopmentMode` leaked in — the entire API is anonymous. Stop and fix before anything else |
| `no pg_hba.conf entry for host ...` after a successful clone | On Debian/Ubuntu `pg_hba.conf` sits outside PGDATA, so the base backup did not bring it. Add the cluster block to the standby and the witness by hand |
| `data directory ... appears to contain a running PostgreSQL instance` | The package install created a cluster there. Stop it and empty the directory before cloning |
| Tenant cannot reach Postgres | `pg_hba.conf` missing the app subnet, `listen_addresses` still localhost, or `PG_SSL_MODE` disagrees with `SHOW ssl;` |
| Writes fail: *cannot execute INSERT in a read-only transaction* | Connected to the standby — `Target Session Attributes=Primary` missing from the connection string |
| `curl https://<public-ip>/health` answers from outside | The origin is exposed. `X-Forwarded-For` is forgeable — fix §6 before going further |

## Things deliberately left for later

- **A log collector.** The tenant now emits structured JSON with `Instance`, `Tenant`,
  `RequestId` and `User` on every line, so `docker logs` is already searchable and an
  error can be traced to one user and one request. What is still missing is somewhere
  central to ship it. Set `Logging__Seq__Url` to turn the sink on — **and add that
  destination to `container-egress.sh`**, or the container will be unable to reach it
  and the sink will buffer and drop in silence.
- **Certificate expiry.** `check-cluster.sh` watches the database and backups;
  nothing watches the Cloudflare Origin certificate, though at 15 years it is not
  urgent.
- **Tenant-to-tenant isolation.** With one tenant it does not bite. Before the second,
  see [ARCHITECTURE.md §5](ARCHITECTURE.md).
- **Outbound e-mail.** Hetzner blocks port 25 and its ranges are widely blocklisted;
  tenant invitations will need a relay, not direct SMTP.
