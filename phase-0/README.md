# Phase 0 — one tenant, end to end

Proves the shape the fleet is built on: **Traefik → one ZuloOne tenant container → its own Postgres database**.
Everything here is done by hand; Phase 1 hands the same steps to the control plane.

```
  browser ──80/443──▶ Traefik ──▶ tenant-t1 (:8080)  ──▶ postgres (db: tenant_t1)
                       edge net        edge + data net       data net (internal)
```

## Run it locally (no DNS, no certificates)

```bash
# 1. Build the tenant image (from the zulo.one repo)
docker build -f src/ZuloOne.Core/Dockerfile -t zuloone/core:dev .

# 2. Configure
cd phase-0
cp .env.example .env      # then fill POSTGRES_PASSWORD, T1_DB_PASSWORD, T1_JWT_KEY

# 3. Up
docker compose up -d
docker compose logs -f tenant-t1
```

> Depending on your install, Compose is either `docker compose` (plugin) or
> `docker-compose` (standalone). Both accept the commands below unchanged.

Open **http://t1.localhost** — browsers resolve `*.localhost` to 127.0.0.1 with no
`hosts` entry needed. First boot runs migrations → schema sync → metadata compile,
so it takes a couple of minutes; watch `docker compose ps` until `tenant-t1` is
`healthy`, or poll `curl -s http://t1.localhost/health`.

The tenant's database starts empty, so the SPA shows **first-run setup**: create the
administrator there. (In Phase 1 the control plane does this via `POST /api/auth/setup`.)

Traefik's own dashboard: http://127.0.0.1:8080 (loopback only).

## Run it on a real host (public DNS + Let's Encrypt)

Add a wildcard DNS record `*.example.com A → <host IP>`, put the ACME variables in
`.env`, then:

```bash
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

A single wildcard certificate (DNS-01) covers every present and future tenant, so
adding a tenant needs neither a DNS change nor a new certificate.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack. Local + plain HTTP by default. |
| `docker-compose.tls.yml` | Overlay: HTTPS, Let's Encrypt wildcard via DNS-01. |
| `postgres/init/10-tenant-t1.sh` | Creates the `tenant_t1` database + owner role on first boot. |
| `.env.example` | Template for secrets and hostnames. |

## What this deliberately does NOT do

Provisioning is manual: adding a second tenant means another service block, another
init script, another set of secrets. That is the point — it exposes exactly the work
the control plane automates in Phase 1 (create DB + role → run container with Traefik
labels → wait for `/health` → seed the admin → record it in the registry).

## Notes

- **Only Traefik publishes ports.** Tenants and Postgres are reachable solely on the
  internal networks, so a tenant can never be hit directly.
- **`data` network is `internal: true`** — no route to the outside world; Traefik is
  intentionally not attached to it.
- **`ZuloOne__BehindReverseProxy=true`** is set on the tenant, not baked into the image:
  it tells Core to honour `X-Forwarded-Proto`. Without it, Core's HTTPS redirect and the
  proxy's plain-HTTP forwarding form an infinite redirect loop.
- **Secrets are `.env`-only for Phase 0.** Docker secrets / a secrets manager come with
  the control plane, which generates a key per tenant.
