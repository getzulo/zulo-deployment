# ZuloOne Deployment

Multi-tenant deployment infrastructure: docker-compose, Traefik, provisioning scripts.

## Phases

- **Phase 0** — one tenant on docker-compose + Traefik (manual), end-to-end TLS
- **Phase 1** — control-plane drives provisioning; Traefik routes by Host label
- **Phase 3** — Kubernetes (later)

## Quick start

### Phase 0 — prove the shape

```bash
cd phase-0
# Traefik + Postgres + one tenant container on t1.zulo.one
docker-compose up
```

## Structure

- `phase-0/` — docker-compose.yml, Traefik config, env templates, smoke-test
- `phase-1/` — control-plane integration, multi-tenant scripts
- `docs/` — deployment runbooks, DNS setup, secrets management
