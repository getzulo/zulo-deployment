#!/bin/bash
# Phase 0 bootstrap: create the first tenant's database and its owner role.
#
# Runs ONCE, when the Postgres data volume is first initialised. In Phase 1 the
# control plane issues exactly these statements per tenant over an admin
# connection — this script is the manual stand-in that proves the shape.
#
# A shell script rather than plain .sql because the password must come from the
# environment: hardcoding it here would silently drift from the connection string
# compose hands the tenant.
set -euo pipefail

: "${T1_DB_PASSWORD:?T1_DB_PASSWORD must be passed to the postgres service}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE ROLE tenant_t1 WITH LOGIN PASSWORD '${T1_DB_PASSWORD}';

    -- Least privilege: the role owns its own database and nothing else, so one
    -- tenant can never read or alter another's data.
    CREATE DATABASE tenant_t1 OWNER tenant_t1;
EOSQL

# PG15+ revoked CREATE on public from non-owners; grant it explicitly so EF Core
# migrations can create the tenant's tables on first boot.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname tenant_t1 <<-EOSQL
    GRANT ALL ON SCHEMA public TO tenant_t1;
EOSQL

echo "bootstrap: database tenant_t1 and role tenant_t1 created"
