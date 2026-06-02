#!/bin/sh
# entrypoint.sh - Start PostgreSQL and run restore if needed

set -e

# Run as postgres user via docker-entrypoint.sh, then restore
# First, call the official postgres entrypoint in background
docker-entrypoint.sh postgres &
PG_PID=$!

echo "⏳ Waiting for PostgreSQL to be ready..."
i=1
while [ $i -le 200 ]; do
    if pg_isready -U "${POSTGRES_USER}" -d "postgres" -q 2>/dev/null; then
        echo "✅ PostgreSQL is ready!"
        break
    fi
    echo "  ... attempt $i/200"
    sleep 2
    i=$((i + 1))
done

# Run restore script (catch failure to prevent infinite container bootloop)
/bin/sh /restore.sh || echo "⚠️ WARNING: Database pull/restore failed! Check the error logs above."

# Keep PostgreSQL running in foreground
wait $PG_PID
