# ZuloOne on the Hetzner ESXi cluster — architecture

Target: tenants in containers, Postgres replicated, everything segmented across the
three subnets that already exist.

## 1. The honest starting point

There are **three ESXi hosts with local disks**, one per subnet. That is better than it
first appears, and it comes with one trap.

**Better:** a standby on a different host than the primary gives real protection against
hardware failure — a dead PSU, disk controller or hypervisor takes one node, not both.
Local disks help too: there is no shared array whose corruption would take both replicas
at once. This is genuine HA, not the appearance of it.

**The trap, and how it is resolved here:** subnets are bound to hosts, so both database
nodes in one subnet would sit on one machine. They are therefore split deliberately —
`zo-pg-1` at **10.10.1.210** (app subnet) and `zo-pg-2` at **10.10.2.210** (data subnet).
Different subnets, different hosts, and a standby that genuinely survives losing the
primary's hardware.

That buys real HA at a real price: the primary shares an L2 segment with the container
host. Traffic from that segment to 5432 never reaches the router, so `pg_hba.conf` and
role permissions are the only thing gating it — the MikroTik cannot help. Container
traffic is still covered, because `container-egress.sh` filters on the host itself (§5).
The CI runner, which executes repository code and was the sharper edge of this, lives in
the core subnet instead and reaches the other tiers only through the router.

**The nodes arbitrate leadership themselves** (§7). Patroni holds a leader key with a TTL
in a three-node etcd cluster; the surviving node takes it and promotes itself, and the
tenant follows within ten seconds. **Measured: 12 s to promote, 10 s for a returned
ex-leader to rewind itself back in as a replica** — including across a full reboot, with
no operator action at either step.

That last part is why this is Patroni rather than repmgr: repmgr has no distributed lock,
so its `node rejoin` is manual by design and a returning ex-primary can only be kept from
resurrecting by procedure. Here the returning node reads the leader key, sees the job is
taken, and demotes itself.

Roles stay swapped afterwards — the cluster is symmetric and there is no "failing back".
A deliberate move is `patronictl switchover`, which waits for the replica to catch up and
therefore costs seconds rather than a failover's dozen.

**What replication still does not cover:** a bad migration, an accidental `DELETE`, or
anything that corrupts data logically — replication faithfully copies all of those to
the standby, immediately. Only the off-site WAL archive recovers from them, and they are
far likelier than hardware failure. If you do one thing from this document, do §8.

## 2. Network map

```
                                Internet
                                    │
                          Cloudflare (proxied)
                                    │ TLS
                              public IP
                                    │
                        ┌───────────┴───────────┐
                        │   MikroTik  10.10.0.1 │  dst-nat 80/443, CF ranges only
                        └───────────┬───────────┘
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
     10.10.0.0/24            10.10.1.0/24            10.10.2.0/24
     CORE / MGMT              APP / DMZ                  DATA
      ESXi host A              ESXi host B             ESXi host C
     ───────────              ─────────                  ────
     gateway   .1             zo-app-1  .220          zo-pg-2  .210
     zo-cp-1   .200           zo-pg-1   .210          (standby)
     zo-ci-1   .210           (primary)
     (+ registry :5000)              │
            │                        └── switched, not routed
            ├──── 5000 registry pull ◀───┘
            ├──── 2375 socket proxy ──▶ zo-app-1
            ├──── 5432 admin ─────────▶ both nodes
            │                        │
            │            5432 ───────┴──────────▶ zo-pg-2
            │                  replication both ways

                          WireGuard ──▶ second machine (off-site)
                                        pgBackRest repo (off-site mirror)
```

Two rules carry most of the security weight:

- **Nothing from the internet reaches `10.10.2.0/24`, ever.** If a tenant container
  is compromised, the attacker meets port 5432 with a role scoped to one database —
  not a shell on the box holding every tenant's data. (Two narrow LAN exceptions exist
  inbound to that subnet: 5432 to the standby, and 53 to the pre-existing resolver at
  `10.10.2.10`. Both are scoped to one host and one port.)
- **The control plane is not in the DMZ.** It lives in the core tier, unreachable from
  Cloudflare, because it is the most valuable target in the system (§4.1).

## 3. VM inventory

vCPU is intentionally oversubscribed — these workloads are bursty and never peak
together. RAM is not oversubscribed; do not let ESXi balloon these.

| VM | Host / subnet | IP | vCPU | RAM | Disk | Role |
|---|---|---|---|---|---|---|
| `zo-cp-1` | core | 10.10.0.200 | 2 | 2 GB | 40 GB | Control plane API + operator dashboard |
| `zo-pgw-1` | core | 10.10.0.220 | 1 | 1 GB | 20 GB | **etcd voter only** — third vote, no PostgreSQL |
| `zo-app-1` | app | 10.10.1.220 | 4 | 8 GB | 120 GB | Docker: Traefik + tenant containers |
| `zo-ci-1` | **core** · 10.10.0.0/24 | 10.10.0.210 | 4 | 8 GB | 150 GB | Actions runner, image builds, registry |
| `zo-pg-1` | **app** · 10.10.1.0/24 | 10.10.1.210 | 4 | 8 GB | 200 GB | Postgres + Patroni + etcd — deliberately not in data, see §1 |
| `zo-pg-2` | data · 10.10.2.0/24 | 10.10.2.210 | 2 | 6 GB | 250 GB | Postgres + Patroni + etcd + pgBackRest repo |

**RAM is per host**, and the three hosts are independent, so there is no single total to
budget against. The app host carries the most: `zo-app-1` (8) + `zo-ci-1` (8) +
`zo-pg-1` (8) = 24 GB, and that host also absorbs the image build, which peaks near 4 GB
on top. The data host carries only the standby, and the core host only the control plane.

If you need to reclaim memory, the standby is the tempting place and the wrong one — it
serves no queries today and becomes the primary the moment you need it.

The control plane stays small on purpose: a .NET API plus a static React bundle making
occasional Docker and Postgres calls. It does not grow with tenant count.

All Ubuntu Server 26.04 LTS. On every VM: **VMware Paravirtual** SCSI controller and **VMXNET3** NIC —
the LSI Logic and E1000 defaults cost real throughput and CPU.

**Why CI gets its own VM.** The image build peaks near 4 GB and saturates every core.
Sharing a VM with the tenant means every push degrades the running product — and on the
app host it already shares silicon with the database primary, which is reason enough to
keep the processes apart.

**Registry lives on `zo-ci-1`** (`10.10.0.210:5000`), because that is where images are
produced. It is in the **core** subnet, so pulls cross the router and need a rule (§9) as
well as one line on the app VM:

```json
/etc/docker/daemon.json → { "insecure-registries": ["10.10.0.210:5000"] }
```

Plain HTTP is acceptable here only because the subnet is private and the registry is
not routable from anywhere else. It is not acceptable the moment that stops being true.

## 4. Control plane — `zo-cp-1`

Provisions tenants: creates the database and role, runs the container with Traefik
labels, gates on `/health`, seeds the first administrator, and keeps a registry of
what exists. Repo: `zulo-control-plane`.

### 4.1 Why it sits in the core tier, not with the app

It is the highest-value target in the system. Compromising it yields, in one step:

- **The Docker socket on `zo-app-1`** — root on the box running every tenant.
- **A Postgres admin connection** — it creates and drops databases, so it holds
  credentials that reach every tenant's data.
- **Its registry rows**, which today store each tenant's `DatabasePassword` and
  `JwtSigningKey` **in plaintext** (`Registry/Tenant.cs` owns this as an interim
  choice). A JWT signing key is enough to mint a valid token for any user of that tenant.

And it currently has **no authentication of any kind** — no `[Authorize]`, no API key,
no operator login. The code says as much in a comment on `Api/TenantsController.cs`.

So: not in the DMZ, no Cloudflare route, no port forward. Operators reach it over
**WireGuard into the core subnet** (or an SSH tunnel). Cloudflare Access is a
reasonable convenience layer *later* — never as the only gate, because with no
app-level auth a single misconfigured Access policy is total compromise.

**Do not deploy it until it has authentication.** The first tenant runs perfectly well
provisioned by hand (README §8); the control plane is an operator convenience that
starts paying off around the fifth tenant.

### 4.2 Reaching Docker without handing over root

`Docker:Host` takes a URI, so the control plane can drive a remote daemon. Do **not**
expose `tcp://` on `zo-app-1` directly: the Docker API has no authentication, and
anything that can reach it is root on that host.

Use a **socket proxy** (Tecnativa `docker-socket-proxy`) on `zo-app-1`, whitelisting
only what provisioning needs — containers create/start/stop/list, images pull, networks
connect — and refusing everything else. The fleet design already anticipates this (§12
of `ControlPlane.Deployment.md`). Then `Docker:Host=tcp://10.10.1.220:2375`, allowed by
the router only from `zo-cp-1`.

### 4.3 Configuration this topology requires

The shipped defaults target phase-0 and will misbehave here. Three settings are already
conditional in the code, so they need values, not code changes:

| Setting | Value | Why |
|---|---|---|
| `Docker:Host` | `tcp://10.10.1.220:2375` | Socket proxy, not a local socket |
| `Fleet:EdgeNetwork` | `zuloone-prod_edge` | Default is `zuloone-phase0_edge` |
| `Fleet:DataNetwork` | *(empty)* | Prod has no data network — Postgres is off-box. Non-empty makes `ConnectNetworkAsync` fail |
| `Fleet:TraefikCertResolver` | *(empty)* | There is no ACME resolver here; the default cert store serves every tenant |
| `TenantDatabase:Host` | `10.10.1.210` | Admin operations go to the primary |
| `TenantDatabase:TenantHost` | `10.10.1.210,10.10.2.210` | What the tenant container gets |

### 4.4 One code change it does need

`Provisioning/TenantDatabaseProvisioner.cs` builds the tenant connection string as:

```
Host={host};Port=...;Database=...;Username=...;Password=...;SSL Mode=Require;Trust Server Certificate=true;
```

Setting `TenantHost` to both nodes produces a multi-host string **without
`Target Session Attributes=Primary`**. Npgsql would then connect to whichever node
answers first — possibly the standby — and every write fails with *cannot execute
INSERT in a read-only transaction*. Append that parameter when the host list contains
a comma. One line, but without it provisioned tenants land on a read-only replica at
random.

Other defects found 2026-09-05 and still open: no `docker pull` before
`CreateContainerAsync` (fails on a host that lacks the tag); admin seeding POSTs to
`http://`, and a 301 turns POST into GET, rolling back the whole tenant; rollback uses
the request's `CancellationToken`, so a browser timeout orphans the container and
database; the registry schema is created with `EnsureCreatedAsync` and has no
migrations. Health probing resolves `{slug}.{RootDomain}` through public DNS — here it
should call Traefik on `zo-app-1` with a `Host` header instead, which avoids hairpinning
back out through Cloudflare.

## 5. Container egress — tenants reach the database and nothing else

The LAN holds resources unrelated to this project, so a tenant container must not be
able to see them. Two gaps make this a host-level problem rather than a router one:

- Containers leave `zo-app-1` **NATed behind the host address**, so on the MikroTik a
  tenant's packets look identical to the VM's own.
- Traffic to anything else in `10.10.1.0/24` **never reaches the router** — it is
  switched. A container could talk to unrelated machines on the subnet and no router
  rule would ever see it.

So the boundary sits on `zo-app-1`, in the `DOCKER-USER` iptables chain — the hook
Docker guarantees it traverses first and never flushes. **Not ufw**: Docker inserts its
rules into `FORWARD` ahead of ufw's, so `ufw deny` does not apply to container traffic
while still reporting the port as blocked.

`container-egress.sh` installs four rules, and the order is load-bearing:

```
1  RETURN  established,related                 return traffic
2  RETURN  -i zo-edge0 -o zo-edge0             Traefik <-> tenant, same bridge
3  RETURN  -i zo-edge0 -d 10.10.1.210/.11 :5432 the one permitted destination
4  DROP    -i zo-edge0                         LAN, metadata, internet - everything
```

Rule 2 is the one that is easy to miss. With `br_netfilter` loaded — Docker loads it —
even same-bridge traffic traverses `FORWARD`, so without it the catch-all breaks the
proxy hop itself and every request 502s.

### Why default-deny is the correct posture, not an aggressive one

Audited against the source: a fresh tenant needs **no egress at all beyond Postgres**.
The AI assistant (`Ai.Enabled`, default false) throws before any HTTP when no key
resolves; outbound integrations (`Integration:Enabled`, default false) queue to the
database and never send; e-mail needs both a flag and a host, both unset. The whole
startup path — migrations, schema sync, Roslyn compile, licence verification — is
Postgres and in-memory only. There is no telemetry, no update check, and JWT uses an
inline symmetric key, so there is no OIDC metadata fetch either.

Open a destination when a feature is switched on, and only that destination.
Outbound SMTP is one such hole: set `SMTP_DESTS="587 465"` (any destination on
those ports — Gmail rotates A records, a pinned IP dies the next day) and re-run
`container-egress.sh --install`. `smtp.gmail.com:587` still pins to today's A
records if you want that. Host `smtp.google.com` is wrong.

### Verified

Exercised end to end on a stand-in stack: the permitted destination stayed reachable
while the internet, private LAN ranges and `169.254.169.254` were all dropped, and the
Traefik hop kept working. The rules survived tearing the network down and recreating
it — which is why the bridge name and subnet are pinned in `docker-compose.yml`. Left
to Compose the bridge is `br-<network-id>` and the subnet is random, so a rule would
silently stop matching after a `down`/`up`, with no visible symptom.

### Tenant-to-tenant

With one tenant this does not bite. A second tenant on the same bridge could reach the
first, because rule 2 permits the whole bridge. The fix is a **network per tenant**
with Traefik attached to each; the control plane already takes the network name as
configuration (`Fleet:EdgeNetwork`), so this is a provisioning change, not a redesign.
Do it before the second tenant, not after.

## 6. How the app finds the primary

Core binds **one** connection string at startup, so after a failover that string has to
land on the new primary by itself. Npgsql 6+ does this natively:

```
Host=10.10.1.210,10.10.2.210;Target Session Attributes=Primary
```

Npgsql probes `pg_is_in_recovery()` before handing out a pooled connection and rechecks
every `Host Recheck Seconds` (10 by default), so it follows a promotion without help.

**No VIP, no HAProxy** — deliberately. A keepalived floating IP would need the ESXi port
group to permit *MAC address changes* and *forged transmits*, which means loosening the
vSwitch for every VM on it. Not worth it when the driver already solves the problem.

One caveat straight from the Npgsql docs: it **never implicitly retries a failed command**
on another host. In-flight statements throw during a failover; the tenant container will
log the error and restart under its `restart: unless-stopped` policy. Expect a blip of
tens of seconds, not a seamless switch.

## 7. Postgres — Patroni topology

```
        etcd quorum (3 nodes, ports 2379/2380, crosses all three subnets)
     zo-pg-1 ────────────── zo-pg-2 ────────────── zo-pgw-1
        │                      │                   (voter only,
        │                      │                    no PostgreSQL)
   ┌────┴──────┐         ┌─────┴─────┐
   │ Patroni   │         │ Patroni   │   whichever holds the leader key
   │ Postgres  │◀────────│ Postgres  │   in etcd is the leader; the other
   └───────────┘  stream └───────────┘   follows it
        │                      │
        └───── WAL archive ──▶ pgBackRest repo (zo-pg-2, mirrored off-site)
```

- **Patroni owns Postgres.** It starts, stops, promotes and demotes the server.
  `start.conf` is `manual` on both nodes so nothing else can race it — never
  `systemctl start postgresql` or `pg_ctlcluster` there.
- **etcd holds the leader key** with a 30-second TTL. Losing it is what triggers an
  election; holding it is what authorises writes. This is a real distributed lock, not
  an advisory vote — which is the whole reason for choosing Patroni over repmgr.
- **Three etcd nodes**, because two cannot form a quorum. The third lives on the core
  ESXi host, so it survives the loss of either machine carrying data.
- **`use_pg_rewind: true`** is what lets a returned ex-leader repair itself instead of
  waiting for an operator. It requires `wal_log_hints: on`, which is set in the same
  block.

Sizing: `shared_buffers` 2 GB / `effective_cache_size` 6 GB on `zo-pg-1` (8 GB), and
1536 MB / 4 GB on `zo-pg-2` (6 GB). Sized per node deliberately — the replica becomes
the leader on failover and has to be sensible on its own.

## 8. Backups — the part that actually saves you

**pgBackRest**, repository on `zo-pg-2`, mirrored to the second machine over WireGuard.

- Full weekly, differential daily, **continuous WAL archiving** — WAL is what turns a
  nightly dump into point-in-time recovery, and PITR is what recovers from a bad
  migration or an accidental `DELETE`, which are far likelier than hardware failure.
- The off-site copy is the only thing that survives the EX63.
- **Restore is not tested until you have restored.** Schedule a quarterly drill that
  restores into a scratch VM and boots a tenant against it.

Do this before real data exists, not after.

**Nothing in the configuration names a primary.** `archive_command` lives in the Patroni
DCS, so both nodes carry it and the leader of the moment uses it; the timers run on the
repository host; pgBackRest asks the cluster who is leading at backup time. A failover
therefore needs no edit anywhere. Getting this wrong is the classic version of this
failure — backups configured against a fixed primary work perfectly until the first
failover, which is also the first time you need them.

**The repository shares a host with a cluster member,** because there is no spare machine.
Two consequences follow, and both are handled rather than avoided:

- On that host `pg1` **must** be its own cluster. `backup` and `check` iterate every
  configured `pgN` and pass either way, but `archive-push` only reads `pg1` — point it at
  a remote host and archiving dies with exit 72, *but only once that node is elected*.
- If the repository host is down while the other leads, WAL cannot be archived.
  `archive-push-queue-max` caps the backlog so `pg_wal` cannot fill the partition and
  take the database down; past the cap, archiving is skipped and PITR continuity breaks
  instead. Availability over recoverability — safe only because §11 notices in minutes.

A dedicated repository host would remove both. It is the first thing to buy.

## 9. Inter-subnet firewall matrix

Enforced on the MikroTik forward chain. Default deny between subnets.

This table governs **VM-to-VM** traffic. Container traffic is NAT'd behind
`zo-app-1` and is governed separately by §5 — the router cannot distinguish it,
and never sees it at all when the destination is on the same subnet.

| From → To | Allowed | Why |
|---|---|---|
| Internet → app | tcp 80,443 **via dst-nat, Cloudflare ranges only** | The only public entry |
| Internet → data | **nothing** | |
| Internet → core | **nothing** | |
| app → data | tcp 5432 | Tenant to the standby, so it can follow a failover |
| app, core → `10.10.2.10` | udp/tcp 53 | The site resolver happens to live in the data subnet. Scoped to that one host — not an opening of the tier |
| app → `zo-pg-1` | **not routed** | Same subnet — switched, never reaches the router. Gated by `pg_hba.conf` and by `container-egress.sh` for containers |
| `zo-pg-1` ↔ `zo-pg-2` | tcp 5432 both ways | Replication crosses the router; the direction reverses after a failover |
| all three nodes ↔ each other | tcp 2379, 2380 | etcd. The nodes are in three subnets, so every quorum message crosses the router. Missing, the cluster never forms and Patroni never starts |
| app → internet | outbound | Image pulls, NuGet, npm during builds |
| data → app | established only | Never initiates |
| data → internet | tcp 443 to package mirrors + WireGuard | Updates and off-site archive |
| core → app, data | tcp 22 | Administration |
| app, data → core | established only | |
| **app → core** | tcp 5000 | Image pulls from the registry on `zo-ci-1`, which is in core. Without it the tenant cannot start |
| **cp → app** | tcp 2375 | Docker socket **proxy** only — never the raw daemon (§4.2) |
| **cp → data** | tcp 5432 | Admin connection: creates/drops tenant databases, plus its own registry DB |
| **cp → app** | tcp 443 | Health probes and admin seeding, addressed to Traefik with a `Host` header rather than out through public DNS |
| **app, data → cp** | established only | The control plane is never called by the tiers it manages |
| **operator → cp** | WireGuard into core | No Cloudflare route, no port forward (§4.1) |

## 10. Failure modes — what is and is not covered

| Failure | Covered | How |
|---|---|---|
| Postgres process crash, data intact | Yes, seconds | Service restarts and resumes as primary — no failover involved |
| `zo-pg-1` or its host dies | Yes, **12 s** unattended | The other node takes the etcd leader key and promotes itself; Npgsql re-probes within 10 s |
| Bad migration, accidental DELETE | Yes | PITR from pgBackRest — **the most likely real incident** |
| Tenant container crash | Yes | `restart: unless-stopped` |
| `zo-app-1` dies | Partly | Redeploy from image; state is in Postgres |
| An ESXi host dies | Yes, **if** the standby is on another host (§1) | Promote; Npgsql follows. Otherwise: restore off-site, hours not seconds |
| Storage corruption on one host | Yes, same condition | Local disks, so the other replica's array is untouched |
| Bad migration replicated to the standby | Only by PITR | Replication copies logical corruption faithfully and instantly — §8 is the only recovery |
| The whole site / datacentre | **No** | Off-site archive onto new hardware |
| Partition between the two nodes | Yes | etcd quorum on a third host breaks the tie; only the node holding the leader key accepts writes |
| etcd quorum lost (2 of 3 nodes down) | Degraded, safe | Patroni refuses to promote without the lock. An outage, never divergence |
| Old leader returns after a failover | Yes, automatically | It finds the leader key held, runs `pg_rewind` and comes back a replica. Verified across a reboot |
| Cloudflare outage | No | Traffic is proxied; a DNS-only fallback record is the escape hatch |
| `zo-cp-1` dies | Yes, by design | Running tenants are untouched — the control plane only provisions. Rebuild it and restore its registry DB from the same cluster backup |
| Tenant container compromised | Contained | Egress limited to Postgres:5432 (§5); the role reaches one database. It cannot see the rest of the LAN |
| **`zo-cp-1` compromised** | **No** | Docker root on the app VM, Postgres admin, and every tenant's JWT key in one place (§4.1). This is why it is not exposed |

## 11. Build order

1. `zo-pg-1`, `zo-pg-2` — cluster and replication first, on empty data
2. pgBackRest + off-site mirror; run one restore drill
3. `zo-app-1` — Docker, then **`container-egress.sh --install` before the first
   tenant starts**, then Traefik and the tenant
4. `zo-ci-1` — runner and registry
5. MikroTik — NAT, Cloudflare allowlist, inter-subnet rules
6. Cloudflare — wildcard record, Full (Strict), Origin certificate
7. Witness on the second machine; only then consider automatic failover
8. **`zo-cp-1` — last, and only after the control plane has authentication.**
   Socket proxy on `zo-app-1` first, then the control plane against it (§4)

Steps 1–2 come first on purpose: they are the ones that are painful to retrofit once
tenants hold data. Step 8 comes last for the opposite reason — nothing depends on it.
The first tenants are provisioned by hand, and the control plane starts earning its
keep around the fifth.

## 12. Deliberately not here yet

- **A central log destination.** Core now logs structured JSON enriched with
  `Instance`, `Tenant`, `Version`, `RequestId` and `User`, plus one completion line per
  request and a global exception handler — so an error is traceable to a user and a
  request without guessing. Shipping it somewhere central is a deployment step:
  `Logging__Seq__Url` turns the sink on, and the destination must also be opened in
  `container-egress.sh` (§5), since a tenant is otherwise locked to Postgres.
- **Certificate expiry monitoring.** `check-cluster.sh` covers the database, backups
  and disk; nothing watches the Origin certificate.
- **A second tenant.** Everything above is written so adding one is a compose entry plus
  a database — no DNS, no certificate, no MikroTik change.
