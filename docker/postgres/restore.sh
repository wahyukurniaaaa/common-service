#!/bin/sh
# restore.sh - Restore PostgreSQL database from .psql dump if not already restored

set -e

# ──────────────────────────────────────────────
# Step 0: Direct Pull Logic (Integrated from sync_posgres.ps1)
# ──────────────────────────────────────────────
DB="${POSTGRES_DB}"
USER="${POSTGRES_USER}"

# ──────────────────────────────────────────────
# 0.1: Check if database exists, create if not
# ──────────────────────────────────────────────
echo "🔍 Checking if local database '${DB}' exists..."
DB_EXISTS=$(psql -U "$USER" -d "postgres" -tAq -c "SELECT 1 FROM pg_database WHERE datname='${DB}'")

if [ "$DB_EXISTS" != "1" ]; then
    echo "🏗️  Database '${DB}' does not exist. Creating..."
    psql -U "$USER" -d "postgres" -c "CREATE DATABASE ${DB}"
fi

# ──────────────────────────────────────────────
# 0.2: Check if database already has tables (idempotent)
# ──────────────────────────────────────────────
echo "🔍 Checking if database '${DB}' has data..."
TABLE_COUNT=$(psql -U "$USER" -d "$DB" -tAq \
    -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema');" \
    2>/dev/null || echo "0")

if [ "$TABLE_COUNT" -gt "0" ]; then
    echo "✅ Database '${DB}' already has data (${TABLE_COUNT} tables), skipping pull."
    exit 0
fi

echo "🔄 Direct Pull: Connecting to ${PG_SOURCE_HOST}:${PG_SOURCE_PORT}..."

# Export password for source connection
export PGPASSWORD="${PG_SOURCE_PASS}"

# Execute pg_dump from source and pipe to psql
# We include the 'sed' fix from sync_posgres.ps1 for v18 compatibility
pg_dump \
    -h "${PG_SOURCE_HOST}" \
    -p "${PG_SOURCE_PORT}" \
    -U "${PG_SOURCE_USER}" \
    --clean --if-exists --no-owner --no-privileges \
    --format=p \
    "${PG_SOURCE_DB}" \
    | sed 's/^SET transaction_timeout = 0;/-- SET transaction_timeout = 0;/' \
    | psql -U "${USER}" -d "${DB}" \
    --set ON_ERROR_STOP=off

if [ $? -eq 0 ]; then
    echo "✅ Database '${DB}' pulled and restored successfully!"
else
    echo "❌ Direct pull failed! Please check if the source service at ${PG_SOURCE_HOST}:${PG_SOURCE_PORT} is accessible."
    exit 1
fi
