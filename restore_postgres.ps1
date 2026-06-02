#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script untuk merestore file SQL lokal ke database PostgreSQL Docker.
.DESCRIPTION
    Script ini memuat konfigurasi target dari file .env dan melakukan restore
    file SQL yang ditentukan menggunakan psql di dalam container Docker.
#>

# Fungsi untuk membaca file .env
function Load-Env {
    param(
        [string]$Path
    )
    if (Test-Path $Path) {
        Get-Content $Path | ForEach-Object {
            $line = $_.Trim()
            # Abaikan komentar dan baris kosong
            if ($line -and -not $line.StartsWith("#") -and $line -like "*=*") {
                $parts = $line.Split('=', 2)
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                # Hapus tanda kutip jika ada
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                [System.Environment]::SetEnvironmentVariable($key, $value)
            }
        }
    }
}

# Load environment variables dari .env di root script
$EnvFile = Join-Path $PSScriptRoot ".env"
Load-Env -Path $EnvFile

# Helper untuk mengambil environment variable dengan fallback
function Get-Env {
    param(
        [string]$Key,
        [string]$Default
    )
    $val = [System.Environment]::GetEnvironmentVariable($Key)
    if ($null -eq $val -or $val -eq "") {
        return $Default
    }
    return $val
}

# ─── PARAMETER MANDATORY / DEFAULT FILE ──────────────────────────────────────
param(
    [string]$SqlFile = "phiro-bns.sql"
)

# ─── KONFIGURASI TUJUAN (TARGET - DOCKER) ─────────────────────────────────────
$TargetPort = Get-Env -Key "PG_PORT" -Default "5435"
$TargetDb   = Get-Env -Key "PG_DB" -Default "phiro_multi_dev"
$TargetUser = Get-Env -Key "PG_USER" -Default "postgres"
$TargetPass = Get-Env -Key "PG_PASSWORD" -Default "postgres"

# ─── KONFIGURASI SUMBER (SOURCE) ──────────────────────────────────────────────
$SourceUser = Get-Env -Key "PG_SOURCE_USER" -Default "phirouser"
$SourcePass = Get-Env -Key "PG_SOURCE_PASS" -Default "PH1r0@ph1raka"

# Validasi Keberadaan File SQL
$AbsoluteSqlPath = Join-Path $PSScriptRoot $SqlFile
if (-not (Test-Path $AbsoluteSqlPath)) {
    Write-Host "      ❌ File SQL tidak ditemukan: $AbsoluteSqlPath" -ForegroundColor Red
    exit 1
}

$SqlFileName = Split-Path $AbsoluteSqlPath -Leaf
$RestoreFile = $AbsoluteSqlPath
$IsTempFile = $false

# ─── STRIP OWNER & PRIVILEGES (OTOMATIS BERSIHKAN UNTUK LOKAL) ────────────────
Write-Host "      🧹 Membersihkan kepemilikan (owner) dan hak akses (grants)..." -ForegroundColor Gray
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TempFileName = "_temp_restore_$Timestamp.sql"
$TempFilePath = Join-Path $PSScriptRoot $TempFileName

$sqlContent = Get-Content -Path $AbsoluteSqlPath -Raw -Encoding UTF8
$sqlContent = $sqlContent -replace "(?mi)^ALTER\s+.*?\s+OWNER\s+TO\s+.*?;", "-- [STRIPPED OWNER]"
$sqlContent = $sqlContent -replace "(?mi)^(GRANT|REVOKE)\s+.*?;", "-- [STRIPPED PRIVILEGES]"

$sqlContent | Set-Content -Path $TempFilePath -Encoding UTF8 -NoNewline

$SqlFileName = $TempFileName
$RestoreFile = $TempFilePath
$IsTempFile = $true

# ─── HELPER: Run Docker dengan Spinner ────────────────────────────────────────
function Invoke-Docker {
    param(
        [string]$Label,
        [string[]]$DockerArgs
    )

    $exitFile = Join-Path $PSScriptRoot ".docker_exit_$PID"

    # Quote each argument to escape any special characters in PowerShell syntax
    $escapedArgs = $DockerArgs | ForEach-Object {
        $escapedVal = $_ -replace "'", "''"
        "'$escapedVal'"
    }
    $argsStr = "@(" + ($escapedArgs -join ", ") + ")"

    $block = [scriptblock]::Create(@"
        `$dockerArgsArray = $argsStr
        `$output = & docker `$dockerArgsArray 2>&1
        `$code   = `$LASTEXITCODE
        `$code | Set-Content -Path '$exitFile'
        `$output
"@)

    $frames  = @("⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏")
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $job     = Start-Job -ScriptBlock $block
    $i       = 0

    try { [Console]::CursorVisible = $false } catch {}
    try {
        while ($job.State -eq "Running") {
            $frame   = $frames[$i % $frames.Length]
            $seconds = [int][math]::Floor($elapsed.Elapsed.TotalSeconds)
            $mins    = [int][math]::Floor($seconds / 60)
            $secs    = [int]($seconds % 60)
            $timer   = "{0:00}:{1:00}" -f $mins, $secs
            Write-Host -NoNewline "`r      $frame $Label  [$timer] " -ForegroundColor Cyan
            Start-Sleep -Milliseconds 80
            $i++
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }

    $elapsed.Stop()

    $jobOutput = Receive-Job -Job $job 2>&1
    Remove-Job -Job $job -Force

    Write-Host -NoNewline "`r"
    Write-Host ("      " + (" " * 60)) -NoNewline
    Write-Host -NoNewline "`r"

    if ($jobOutput) {
        $jobOutput | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line) { Write-Host "      ⚪ $line" -ForegroundColor DarkGray }
        }
    }

    $exitCode = 0
    if (Test-Path $exitFile) {
        $exitCode = [int](Get-Content $exitFile -Raw).Trim()
        Remove-Item $exitFile -ErrorAction SilentlyContinue
    }

    return $exitCode
}

# ══════════════════════════════════════════════════════════════════════════════
Write-Host ("═" * 60) -ForegroundColor Cyan
Write-Host " 🚀 LOCAL POSTGRESQL RESTORE: SQL FILE -> DOCKER" -ForegroundColor Cyan
Write-Host " Source File: $SqlFileName"
Write-Host " Target DB  : 127.0.0.1:${TargetPort} ($TargetDb)"
Write-Host " Time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("═" * 60) -ForegroundColor Cyan

try {
    # ─── PRE-RESTORE: Buat Role Sumber di Target (jika belum ada) ─────────────────
    if ($SourceUser -ne $TargetUser) {
        $createRoleSql = "DO `$`$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$SourceUser') THEN CREATE ROLE $SourceUser WITH LOGIN PASSWORD '$SourcePass' SUPERUSER; END IF; END `$`$;"
        $roleArgs = @(
            "run", "--rm",
            "-e", "PGPASSWORD=$TargetPass",
            "postgres:18-alpine",
            "psql",
            "--host=host.docker.internal",
            "--port=$TargetPort",
            "--username=$TargetUser",
            "--dbname=postgres",
            "-c", $createRoleSql
        )
        Invoke-Docker -Label "Memverifikasi role '$SourceUser' di target" -DockerArgs $roleArgs | Out-Null
    }

    # ─── RESTORE KE DOCKER ────────────────────────────────────────────────────────
    Write-Host "`n[1/1] 📤 Merestore file SQL ke target Docker..." -ForegroundColor Yellow

    $restoreArgs = @(
        "run", "--rm",
        "-v", "${PSScriptRoot}:/backup",
        "-e", "PGPASSWORD=$TargetPass",
        "postgres:18-alpine",
        "psql",
        "--host=host.docker.internal",
        "--port=$TargetPort",
        "--username=$TargetUser",
        "--dbname=$TargetDb",
        "--file=/backup/$SqlFileName",
        "--set", "ON_ERROR_STOP=on"
    )

    $exitCode = Invoke-Docker -Label "Menjalankan psql restore" -DockerArgs $restoreArgs

    if ($exitCode -ne 0) {
        Write-Host "      ⚠️  Restore gagal. Mencoba bersihkan database '$TargetDb' lalu retry..." -ForegroundColor Yellow

        # Drop database lama jika ada
        $dropArgs = @(
            "run", "--rm",
            "-e", "PGPASSWORD=$TargetPass",
            "postgres:18-alpine",
            "psql",
            "--host=host.docker.internal",
            "--port=$TargetPort",
            "--username=$TargetUser",
            "--dbname=postgres",
            "-c", "DROP DATABASE IF EXISTS $TargetDb WITH (FORCE);"
        )
        Invoke-Docker -Label "Menghapus database lama" -DockerArgs $dropArgs | Out-Null

        # Buat ulang database
        $createArgs = @(
            "run", "--rm",
            "-e", "PGPASSWORD=$TargetPass",
            "postgres:18-alpine",
            "psql",
            "--host=host.docker.internal",
            "--port=$TargetPort",
            "--username=$TargetUser",
            "--dbname=postgres",
            "-c", "CREATE DATABASE $TargetDb;"
        )
        Invoke-Docker -Label "Membuat database baru" -DockerArgs $createArgs | Out-Null

        # Retry restore
        $exitCode = Invoke-Docker -Label "Retry psql restore" -DockerArgs $restoreArgs

        if ($exitCode -ne 0) {
            Write-Host "      ❌ Restore gagal setelah retry! (exit code: $exitCode)" -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "      ✅ Restore berhasil!" -ForegroundColor Green
} finally {
    if ($IsTempFile -and (Test-Path $RestoreFile)) {
        Remove-Item $RestoreFile -ErrorAction SilentlyContinue
        Write-Host "  🗑️  File sementara bersih-bersih telah dihapus." -ForegroundColor Gray
    }
}

# ─── SELESAI ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 60) -ForegroundColor Cyan
Write-Host "  ✨ RESTORE SELESAI!" -ForegroundColor Cyan
Write-Host ("═" * 60) -ForegroundColor Cyan




