#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate file SQL INSERT untuk migrasi data MSSQL → PostgreSQL
.DESCRIPTION
    Menggunakan sqlcmd di dalam Docker container untuk export data
    lalu generate PostgreSQL-compatible INSERT statements
.USAGE
    .\generate_migration_sql.ps1
#>

# ─── Load .env ────────────────────────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot ".env"
Get-Content $envFile | Where-Object { $_ -match "^[^#].+=.+" } | ForEach-Object {
    $parts = $_ -split "=", 2
    [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim())
}

$SA_PASS   = if ($env:MSSQL_PASSWORD) { $env:MSSQL_PASSWORD } else { $env:MSSQL_SA_PASSWORD }
$DB        = if ($env:MSSQL_DB) { $env:MSSQL_DB } else { $env:DB_NAME }
$FROM_DATE = $env:MIGRATE_FROM_DATE
$CONTAINER = "common-mssql"
$SQLCMD    = "/opt/mssql-tools18/bin/sqlcmd"
$TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"
$OUTPUT    = Join-Path $PSScriptRoot "migration_smartoffice_$TIMESTAMP.sql"

$TABLES = @(
    "eof_memos",
    "eof_memo_recipients",
    "eof_memo_senders",
    "eof_memo_copies",
    "eof_memo_documents",
    "eof_memo_feedbacks",
    "eof_memo_options",
    "eof_memo_actions",
    "eof_memo_action_instructions",
    "eof_memo_action_distributions",
    "eof_memo_action_distribution_types"
)

Write-Host "=" * 60
Write-Host "  Generate Migration SQL: MSSQL → PostgreSQL"
Write-Host "  Filter  : ctime >= $FROM_DATE"
Write-Host "  Output  : $OUTPUT"
Write-Host "=" * 60

# ─── Helper: jalankan sqlcmd di container ──────────────────────────────────────
function Invoke-Sqlcmd-Docker {
    param([string]$Query)
    $result = docker exec $CONTAINER $SQLCMD `
        -S localhost -U sa -P $SA_PASS `
        -d $DB -No -C -W -s"|" `
        -Q $Query 2>&1
    return $result
}

# ─── Helper: escape string untuk PostgreSQL ────────────────────────────────────
function Escape-PgString {
    param([string]$val)
    return $val.Replace("'", "''").Replace("\", "\\")
}

# ─── Tulis header SQL ──────────────────────────────────────────────────────────
$genTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$header = @"
-- ═══════════════════════════════════════════════════════════
--  Migration: SQL Server → PostgreSQL
--  Source DB : $DB
--  Generated : $genTime
--  Filter    : ctime >= '$FROM_DATE'
-- ═══════════════════════════════════════════════════════════
--  Cara pakai:
--    psql -h <host> -U <user> -d <dbname> -f $(Split-Path $OUTPUT -Leaf)
-- ═══════════════════════════════════════════════════════════

SET client_encoding = 'UTF8';
BEGIN;

"@
$header | Out-File -FilePath $OUTPUT -Encoding utf8

$totalRows  = 0
$maxIds     = @{}   # table -> max id value untuk reset sequence

foreach ($table in $TABLES) {
    Write-Host "`n  📦 $table" -NoNewline

    # ── Ambil data ──────────────────────────────────────────────────────────────
    $dataQuery = "SET NOCOUNT ON; SELECT * FROM $table WHERE ctime >= '$FROM_DATE 00:00:00'"
    $dataResult = Invoke-Sqlcmd-Docker -Query $dataQuery

    # Parse: baris 0 = header kolom, baris 1 = garis pemisah, baris 2+ = data
    $lines = $dataResult | Where-Object { $_ -and $_ -notmatch "^\s*$" }

    if ($lines.Count -lt 3) {
        Write-Host " ... ℹ️  tidak ada data"
        "-- ℹ️  $table : tidak ada data sejak $FROM_DATE`n" |
            Out-File -FilePath $OUTPUT -Encoding utf8 -Append
        continue
    }

    # Kolom dari baris pertama (pipe-delimited)
    $columns = $lines[0] -split "\|" | ForEach-Object { $_.Trim().ToLower() }
    $colList = ($columns | ForEach-Object { "`"$_`"" }) -join ", "
    $pkCol   = $columns[0]   # asumsi kolom pertama = primary key

    # Data: skip header (baris 0) dan separator (baris 1)
    $dataLines = $lines | Select-Object -Skip 2

    $tableSection = @()
    $tableSection += ""
    $tableSection += "-- ═══════════════════════════════════════════"
    $tableSection += "-- Table: $table  ($($dataLines.Count) rows)"
    $tableSection += "-- ═══════════════════════════════════════════"
    $tableSection += ""

    $rowCount = 0
    $maxId    = 0
    foreach ($dataLine in $dataLines) {
        $cells = $dataLine -split "\|"
        if ($cells.Count -ne $columns.Count) { continue }

        $vals = @()
        $cellIdx = 0
        foreach ($cell in $cells) {
            $cell = $cell.Trim()
            if ($cell -eq "" -or $cell -eq "NULL") {
                $vals += "NULL"
            } elseif ($cell -match "^\d+$") {
                $vals += $cell
                # Track max PK (kolom pertama)
                if ($cellIdx -eq 0 -and [int64]$cell -gt $maxId) { $maxId = [int64]$cell }
            } elseif ($cell -match "^\d+\.\d+$") {
                $vals += $cell
            } else {
                $escaped = Escape-PgString -val $cell
                $vals += "'$escaped'"
            }
            $cellIdx++
        }

        $valList = $vals -join ", "
        $tableSection += "INSERT INTO `"$table`" ($colList) VALUES ($valList) ON CONFLICT DO NOTHING;"
        $rowCount++
    }

    $tableSection += ""
    $tableSection | Out-File -FilePath $OUTPUT -Encoding utf8 -Append
    $totalRows += $rowCount
    if ($maxId -gt 0) { $maxIds[$table] = @{ pk = $pkCol; maxId = $maxId } }
    Write-Host " ✅ $rowCount rows  (max $pkCol = $maxId)"
}

# ─── Footer: COMMIT + Reset Sequences ────────────────────────────────────────
$seqSection = @()
$seqSection += ""
$seqSection += "COMMIT;"
$seqSection += ""
$seqSection += "-- ═══════════════════════════════════════════════════════════"
$seqSection += "-- Reset sequences agar auto-increment tidak bentrok dengan data yang sudah ada"
$seqSection += "-- ═══════════════════════════════════════════════════════════"
$seqSection += ""

foreach ($tbl in $maxIds.Keys) {
    $pk    = $maxIds[$tbl].pk
    # Nama sequence PostgreSQL default: <table>_<pk>_seq
    $seqName = "${tbl}_${pk}_seq"
    $seqSection += "SELECT setval('$seqName', COALESCE((SELECT MAX($pk) FROM `"$tbl`"), 1));"
}

$seqSection += ""
$seqSection += "-- ═══════════════════════════════════════════════════════════"
$seqSection += "--  Total rows : $totalRows"
$seqSection += "--  Generated  : $genTime"
$seqSection += "-- ═══════════════════════════════════════════════════════════"

$seqSection | Out-File -FilePath $OUTPUT -Encoding utf8 -Append

$fileSize = (Get-Item $OUTPUT).Length
Write-Host "`n$("="*60)"
Write-Host "  ✅ Selesai! Total: $($totalRows.ToString('N0')) rows"
Write-Host "  📄 File : $OUTPUT"
Write-Host "  📏 Size : $($fileSize.ToString('N0')) bytes"
Write-Host "$("="*60)"
Write-Host "`n  Jalankan di production:"
Write-Host "  psql -h <host> -U postgres -d smartoffice -f $(Split-Path $OUTPUT -Leaf)`n"

