#!/bin/bash
# entrypoint.sh - Start SQL Server and run restore if needed

set -e

# Start SQL Server in background
/opt/mssql/bin/sqlservr &
SQLPID=$!

echo "⏳ Waiting for SQL Server to start..."
# Wait until SQL Server is accepting connections
for i in {1..30}; do
    if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT 1" -No -C &>/dev/null; then
        echo "✅ SQL Server is ready!"
        break
    fi
    echo "  ... attempt $i/30"
    sleep 3
done

# Run restore script (catch failure to prevent infinite container bootloop)
/bin/bash /restore.sh || echo "⚠️ WARNING: Database restore failed! Check the error logs above."

# Keep SQL Server running in foreground
wait $SQLPID
