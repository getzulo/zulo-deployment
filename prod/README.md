# ZuloOne — production deployment

Tenants in containers on an ESXi cluster, fronted by Cloudflare, backed by a replicated
Postgres.

```
browser ──TLS──▶ Cloudflare ──TLS──▶ public IP ──dst-nat──▶ zo-app-1 ──▶ Traefik ──▶ container
                 (proxied)           MikroTik              10.10.1.220     :443        :8080
                                     CF ranges only                                      │
                                                                                 5432    ▼
                                                    zo-pg-1 / zo-pg-2  ◀──────  data tier
                                                    (Patroni + etcd, streaming replication)
```

## Where to look

| | |
|---|---|
| **[ARCHITECTURE.md](ARCHITECTURE.md)** | *Why* — network map, machine inventory, container egress, failure analysis, where the control plane fits |
| **[INSTALL.md](INSTALL.md)** | *How* — build it from zero, phase by phase, with a checkpoint after each |

Read ARCHITECTURE first. INSTALL assumes you have.

## Files here

| File | Runs where | Purpose |
|---|---|---|
| `docker-compose.yml` | `zo-app-1` | Traefik + one tenant. Standalone, **not** an overlay on phase-0 |
| `docker-compose.socket-proxy.yml` | `zo-app-1` | Docker socket proxy — only when the control plane exists |
| `traefik/dynamic/tls.yml` | `zo-app-1` | TLS store for the Cloudflare Origin certificate. No ACME anywhere |
| `first-boot.sh` | every new VM | Installs the basics and verifies the machine against the plan — address, gateway, resolver, inter-tier reachability |
| `bootstrap.sh` | `zo-app-1`, `zo-ci-1` | Docker, `deploy` user, SSH hardening, registry. Role-aware: `ROLE=ci` |
| `container-egress.sh` | `zo-app-1` | Locks tenants to Postgres and nothing else |
| `check-cluster.sh` | `zo-pg-1`, `zo-pg-2` | Timer-driven: etcd quorum, Patroni member states, replication lag, WAL archiving, backup age, disk |
| `mikrotik.rsc` | the router | Cloudflare allowlist, destination NAT, inter-tier policy |
| `.env.example` | `zo-app-1` | Copy to `.env`. Never commit the real one |

## Five things that bite

1. **Cloudflare must be Full (Strict).** On *Flexible* the origin gets plain HTTP,
   Traefik redirects to HTTPS, and the browser loops through Cloudflare forever.
2. **`Workspace__Path` must stay unset.** `WorkspaceSyncService` also reads its path
   from the database, bypassing the dev gate. If it ever resolves one in production, a
   watcher exports the whole metadata surface to disk, **deletes orphan files there**,
   and imports anything edited in that folder back into the live database.
3. **`ZuloOne__CoreDevelopmentMode` must stay unset.** It defaults to `false`, which is
   what installs the global `RequireAuthenticatedUser` policy. True makes the entire API
   anonymous. The root `docker-compose.yml` in `zulo.one` sets it true — that file is
   the dev stand and must never be used here.
4. **Postgres belongs to Patroni.** Never `systemctl start postgresql` or
   `pg_ctlcluster` on the data nodes — `start.conf` is `manual` and must stay that way,
   or a manual start races Patroni. Everything goes through
   `patronictl -c /etc/patroni/config.yml`.
5. **Never `ufw` on the container host.** Docker writes its rules into `FORWARD` ahead
   of ufw's, so `ufw deny` leaves container traffic flowing while reporting the port
   blocked. Use `container-egress.sh` and the MikroTik.

## Verified vs not

Exercised locally against a stand-in stack: the tenant connects with
`SSL Mode=Require`, Traefik serves the wildcard by SNI, `/health` reports the right
version through the proxy, `:80` redirects, unknown hosts 404, `/api/...` returns 401,
and the egress lockdown blocks the LAN and the internet while preserving the proxy hop.

Not verified, for want of the hardware: `mikrotik.rsc`, the ESXi steps, and the
pgBackRest commands. Import the router config with console access at hand.

The Postgres cluster itself IS verified — built, failed over and recovered on the real
hardware; see ARCHITECTURE.md §7.
