#!/bin/bash
# restore.sh - Direct Pull or File-based Restore for SQL Server database

set -e

DB="${DB_NAME}"
SA_PASS="${SA_PASSWORD}"
DATA_DIR="/var/opt/mssql/data"
TMP_RESTORE_DIR="/tmp/extracted" # Use container's /tmp since /var/opt/mssql/backup is read-only

# ──────────────────────────────────────────────
# Step 0: Check if database already exists (idempotent)
# ──────────────────────────────────────────────
DB_EXISTS=$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASS" -No -C \
  -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '${DB}'" \
  2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]')

if [ "$DB_EXISTS" = "1" ]; then
    echo "✅ Database '${DB}' already exists, skipping restore."
    exit 0
fi

# ──────────────────────────────────────────────
# Step 1: Attempt Direct Pull using sqlpackage if source is configured
# ──────────────────────────────────────────────
if [ -n "${MSSQL_SOURCE_HOST}" ] && [ "${MSSQL_SOURCE_HOST}" != "none" ]; then
    echo "🔄 Direct Pull: Connecting to remote SQL Server at ${MSSQL_SOURCE_HOST}:${MSSQL_SOURCE_PORT}..."
    
    # Install sqlpackage if not already present
    if ! command -v sqlpackage &> /dev/null && [ ! -f /opt/sqlpackage/sqlpackage ]; then
        echo "🔧 Installing sqlpackage utility from Microsoft..."
        apt-get update && apt-get install -y wget unzip libunwind8 libicu-dev &>/dev/null
        wget -q https://aka.ms/sqlpackage-linux -O /tmp/sqlpackage.zip
        mkdir -p /opt/sqlpackage
        unzip -o -q /tmp/sqlpackage.zip -d /opt/sqlpackage
        chmod +x /opt/sqlpackage/sqlpackage
        rm -f /tmp/sqlpackage.zip
    fi
    export PATH="$PATH:/opt/sqlpackage"
    
    BACPAC_PATH="/tmp/temp_db.bacpac"
    echo "📥 Exporting remote database '${MSSQL_SOURCE_DB}' to temporary bacpac..."
    
    if /opt/sqlpackage/sqlpackage /Action:Export \
        /SourceServerName:"${MSSQL_SOURCE_HOST},${MSSQL_SOURCE_PORT}" \
        /SourceDatabaseName:"${MSSQL_SOURCE_DB}" \
        /SourceUser:"${MSSQL_SOURCE_USER}" \
        /SourcePassword:"${MSSQL_SOURCE_PASS}" \
        /TargetFile:"$BACPAC_PATH" \
        /p:VerifyFullTextCatalogReady=False; then
        
        echo "✅ Export successful. Importing to local database '${DB}'..."
        
        # Check if database exists, create if not
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASS" -No -C -Q "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'${DB}') CREATE DATABASE [${DB}]"
        
        if /opt/sqlpackage/sqlpackage /Action:Import \
            /TargetServerName:"localhost" \
            /TargetDatabaseName:"${DB}" \
            /TargetUser:"sa" \
            /TargetPassword:"$SA_PASS" \
            /SourceFile:"$BACPAC_PATH" \
            /p:DatabaseEdition=Standard; then
            
            echo "✅ Database '${DB}' pulled and restored successfully!"
            rm -f "$BACPAC_PATH"
            exit 0
        else
            echo "❌ Import failed!"
            rm -f "$BACPAC_PATH"
            exit 1
        fi
    else
        echo "⚠️ Direct pull failed! Falling back to local file restore if available..."
    fi
fi

# ──────────────────────────────────────────────
# Step 2: Fallback - Auto-Discover and Restore from local backup file (.zip / .bak)
# ──────────────────────────────────────────────
if [ -z "${DB_BAK_FILE}" ]; then
    echo "🔍 DB_BAK_FILE not specified. Searching for latest .zip or .bak in project root..."
    LATEST_FILE=$(find /var/opt/mssql/backup -maxdepth 1 \( -name "*.zip" -o -name "*.bak" \) | head -n 1)
    if [ -n "$LATEST_FILE" ]; then
        BACKUP_PATH="$LATEST_FILE"
        echo "📂 Auto-discovered backup file: $BACKUP_PATH"
    else
        echo "❌ No local backup file (.zip or .bak) found for fallback!"
        exit 1
    fi
else
    BACKUP_PATH="/var/opt/mssql/backup/${DB_BAK_FILE}"
    if [ ! -f "$BACKUP_PATH" ]; then
        BACKUP_PATH="/var/opt/mssql/backup/$(basename "${DB_BAK_FILE}")"
    fi
fi

# Handle ZIP files if needed
if [[ "$BACKUP_PATH" == *.zip ]]; then
    echo "📦 ZIP file detected. Extracting..."
    if ! command -v unzip &> /dev/null; then
        echo "🔧 Installing unzip..."
        apt-get update && apt-get install -y unzip
    fi
    mkdir -p "$TMP_RESTORE_DIR"
    unzip -o -q "$BACKUP_PATH" -d "$TMP_RESTORE_DIR"
    EXTRACTED_BAK=$(find "$TMP_RESTORE_DIR" -name "*.bak" | head -n 1)
    if [ -z "$EXTRACTED_BAK" ]; then
        echo "❌ No .bak file found inside the zip!"
        exit 1
    fi
    echo "✅ Found extracted backup: $EXTRACTED_BAK"
    BACKUP_PATH="$EXTRACTED_BAK"
fi

echo "🔄 Starting restore of '${DB}' from $(basename "$BACKUP_PATH")..."

# Get logical file names via FILELISTONLY
echo "📋 Reading file list from backup..."
TMPFILE=$(mktemp)
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASS" -No -C -s"|" -W \
  -Q "RESTORE FILELISTONLY FROM DISK = N'${BACKUP_PATH}'" 2>/dev/null > "$TMPFILE"

DATA_LOGICAL=$(awk -F'|' 'NR>2 && $3 == "D" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit }' "$TMPFILE")
LOG_LOGICAL=$(awk  -F'|' 'NR>2 && $3 == "L" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit }' "$TMPFILE")
rm -f "$TMPFILE"

echo "📂 Data logical file : '$DATA_LOGICAL'"
echo "📂 Log  logical file : '$LOG_LOGICAL'"

if [ -z "$DATA_LOGICAL" ] || [ -z "$LOG_LOGICAL" ]; then
    echo "❌ Could not detect logical file names from backup!"
    exit 1
fi

# Restore database
echo "🔄 Restoring database '${DB}'..."
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASS" -No -C -Q "
RESTORE DATABASE [${DB}]
FROM DISK = N'${BACKUP_PATH}'
WITH
    MOVE N'${DATA_LOGICAL}' TO N'${DATA_DIR}/${DB}.mdf',
    MOVE N'${LOG_LOGICAL}'  TO N'${DATA_DIR}/${DB}_log.ldf',
    REPLACE,
    STATS = 10;
"

if [ $? -eq 0 ]; then
    echo "✅ Database '${DB}' restored successfully from file!"
    # Cleanup extracted temp directory if we unzipped it
    rm -rf "$TMP_RESTORE_DIR"
else
    echo "❌ Restore failed!"
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi
