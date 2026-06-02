#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script untuk sinkronisasi database PostgreSQL: Backup dari Server -> Restore ke Docker.
.DESCRIPTION
    Script ini menggunakan pg_dump untuk mengambil data dari server sumber
    dan psql untuk merestore-nya ke container Docker lokal.
    Dilengkapi dengan spinner animasi agar tidak terlihat stuck.
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

# ─── KONFIGURASI SUMBER (SOURCE) ──────────────────────────────────────────────
$SourcePort = Get-Env -Key "PG_SOURCE_PORT" -Default "55321"
$SourceDb   = Get-Env -Key "PG_SOURCE_DB" -Default "phiro_multi_dev"
$SourceUser = Get-Env -Key "PG_SOURCE_USER" -Default "phirouser"
$SourcePass = Get-Env -Key "PG_SOURCE_PASS" -Default "PH1r0@ph1raka"

# ─── KONFIGURASI TUJUAN (TARGET - DOCKER) ─────────────────────────────────────
$TargetPort = Get-Env -Key "PG_PORT" -Default "5435"
$TargetDb   = Get-Env -Key "PG_DB" -Default "phiro_multi_dev"
$TargetUser = Get-Env -Key "PG_USER" -Default "postgres"
$TargetPass = Get-Env -Key "PG_PASSWORD" -Default "postgres"

# ─── SETUP FILE BACKUP ────────────────────────────────────────────────────────
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupFileName = "sync_$($TargetDb)_$Timestamp.sql"
$BackupFile     = Join-Path $PSScriptRoot $BackupFileName

# ─── HELPER: Cleanup ──────────────────────────────────────────────────────────
function Cleanup {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    if (Test-Path $BackupFile) {
        Remove-Item $BackupFile -ErrorAction SilentlyContinue
        Write-Host "  🗑️  File backup sementara telah dihapus." -ForegroundColor Gray
    }
}

# ─── HELPER: Run Docker dengan Spinner ────────────────────────────────────────
# Wrapper khusus untuk `docker run` agar exit code bisa ditangkap dari background job.
function Invoke-Docker {
    param(
        [string]$Label,
        [string[]]$DockerArgs
    )

    # Simpan exit code ke file sementara karena background job tidak bisa return $LASTEXITCODE langsung
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

    # Cetak output docker (warning/notice dari pg_dump/psql)
    $jobOutput = Receive-Job -Job $job 2>&1
    Remove-Job -Job $job -Force

    Write-Host -NoNewline "`r" # Hapus baris spinner
    Write-Host ("      " + (" " * 60)) -NoNewline # Clear sisa teks
    Write-Host -NoNewline "`r"

    if ($jobOutput) {
        $jobOutput | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line) { Write-Host "      ⚪ $line" -ForegroundColor DarkGray }
        }
    }

    # Baca exit code dari file
    $exitCode = 0
    if (Test-Path $exitFile) {
        $exitCode = [int](Get-Content $exitFile -Raw).Trim()
        Remove-Item $exitFile -ErrorAction SilentlyContinue
    }

    return $exitCode
}

# ══════════════════════════════════════════════════════════════════════════════
Write-Host ("═" * 60) -ForegroundColor Cyan
Write-Host " 🚀 POSTGRESQL DB SYNC: SERVER -> DOCKER" -ForegroundColor Cyan
Write-Host " Source: 127.0.0.1:${SourcePort} ($SourceDb)"
Write-Host " Target: 127.0.0.1:${TargetPort} ($TargetDb)"
Write-Host " Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("═" * 60) -ForegroundColor Cyan

# ─── STEP 1: BACKUP DARI SUMBER ───────────────────────────────────────────────
Write-Host "`n[1/2] 📥 Mengambil backup dari server sumber..." -ForegroundColor Yellow
Write-Host "      File: $BackupFile"

$dumpArgs = @(
    "run", "--rm",
    "-v", "${PSScriptRoot}:/backup",
    "-e", "PGPASSWORD=$SourcePass",
    "postgres:18-alpine",
    "pg_dump",
    "--host=host.docker.internal",
    "--port=$SourcePort",
    "--username=$SourceUser",
    "--clean", "--if-exists", "--no-owner", "--no-privileges",
    "--format=p",
    "--file=/backup/$BackupFileName",
    $SourceDb
)

$exitCode = Invoke-Docker -Label "Menjalankan pg_dump" -DockerArgs $dumpArgs

if ($exitCode -ne 0) {
    Write-Host "      ❌ Gagal mengambil backup! (exit code: $exitCode)" -ForegroundColor Red
    Cleanup
    exit 1
}
Write-Host "      ✅ Backup berhasil! " -ForegroundColor Green

# ─── CLEANUP: Strip parameter v18 yang tidak kompatibel ───────────────────────
Write-Host "      🧹 Membersihkan parameter v18..." -ForegroundColor Gray

if (-not (Test-Path $BackupFile)) {
    Write-Host "      ❌ File backup tidak ditemukan setelah dump!" -ForegroundColor Red
    Cleanup
    exit 1
}

$content = Get-Content -Path $BackupFile -Raw -Encoding UTF8
$content = $content -replace "(?m)^SET transaction_timeout = 0;", "-- SET transaction_timeout = 0;"
$content | Set-Content -Path $BackupFile -Encoding UTF8 -NoNewline
Write-Host "      ✅ File backup siap." -ForegroundColor Green

# ─── STEP 2: RESTORE KE DOCKER ────────────────────────────────────────────────
Write-Host "`n[2/2] 📤 Merestore ke target Docker (127.0.0.1:${TargetPort})..." -ForegroundColor Yellow

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
    "--file=/backup/$BackupFileName",
    "--set", "ON_ERROR_STOP=on"
)

$exitCode = Invoke-Docker -Label "Menjalankan psql restore" -DockerArgs $restoreArgs

if ($exitCode -ne 0) {
    Write-Host "      ⚠️  Restore gagal. Mencoba buat database '$TargetDb' lalu retry..." -ForegroundColor Yellow

    # Coba buat database
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
    Invoke-Docker -Label "Membuat database" -DockerArgs $createArgs | Out-Null

    # Retry restore
    $exitCode = Invoke-Docker -Label "Retry psql restore" -DockerArgs $restoreArgs

    if ($exitCode -ne 0) {
        Write-Host "      ❌ Restore gagal setelah retry! (exit code: $exitCode)" -ForegroundColor Red
        Cleanup
        exit 1
    }
}

Write-Host "      ✅ Restore berhasil!" -ForegroundColor Green

# ─── SELESAI ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 60) -ForegroundColor Cyan
Write-Host "  ✨ SINKRONISASI SELESAI!" -ForegroundColor Cyan
Cleanup
Write-Host ("═" * 60) -ForegroundColor Cyan

