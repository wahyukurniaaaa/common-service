#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script untuk sinkronisasi database SQL Server (MSSQL): Restore paksa di Docker.
.DESCRIPTION
    Script ini memicu restore database MSSQL dari berkas backup (.bak / .zip)
    yang dikonfigurasi di berkas .env.
    Dilengkapi dengan spinner animasi agar tidak terlihat stuck.
#>

# ─── BACA KONFIGURASI DARI .ENV ───────────────────────────────────────────────
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$EnvFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path $EnvFile)) {
    Write-Host "❌ Berkas .env tidak ditemukan di $PSScriptRoot!" -ForegroundColor Red
    exit 1
}

# Helper: Memuat .env
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2) {
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            Set-Content "env:$key" $val
        }
    }
}

$DbName     = if ($env:MSSQL_DB) { $env:MSSQL_DB } else { $env:DB_NAME }
$SaPassword = if ($env:MSSQL_PASSWORD) { $env:MSSQL_PASSWORD } else { $env:MSSQL_SA_PASSWORD }
$Port       = if ($env:MSSQL_PORT) { $env:MSSQL_PORT } else { "1433" }
$BakFile    = $env:DB_BAK_FILE

if (-not $DbName -or -not $SaPassword) {
    Write-Host "❌ Konfigurasi SQL Server di .env tidak lengkap! Pastikan MSSQL_DB dan MSSQL_PASSWORD terisi." -ForegroundColor Red
    exit 1
}

# ─── HELPER: Run Docker dengan Spinner ────────────────────────────────────────
function Invoke-Docker {
    param(
        [string]$Label,
        [string[]]$DockerArgs
    )

    $exitFile = Join-Path $PSScriptRoot ".docker_exit_$PID"

    $block = [scriptblock]::Create(@"
        `$output = docker $($DockerArgs -join ' ') 2>&1
        `$code   = `$LASTEXITCODE
        `$code | Set-Content -Path '$exitFile'
        `$output
"@)

    $frames  = @("⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏")
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $job     = Start-Job -ScriptBlock $block
    $i       = 0

    [Console]::CursorVisible = $false
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
        [Console]::CursorVisible = $true
    }

    $elapsed.Stop()

    $jobOutput = Receive-Job -Job $job 2>&1
    Remove-Job -Job $job -Force

    Write-Host -NoNewline "`r" # Clear line
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
Write-Host " 🚀 SQL SERVER DB SYNC: RE-RESTORE DOCKER" -ForegroundColor Cyan
Write-Host " Target Container: common-mssql"
Write-Host " Target Database : $DbName"
Write-Host " Backup File     : $BakFile"
Write-Host " Time            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("═" * 60) -ForegroundColor Cyan

# ─── STEP 0: KONFIRMASI ───────────────────────────────────────────────────────
Write-Host ""
$Confirm = Read-Host "⚠️  PERINGATAN: Proses ini akan menghapus database '$DbName' di Docker lokal terlebih dahulu. Lanjutkan? (y/N)"
if ($Confirm.ToLower() -ne "y" -and $Confirm.ToLower() -ne "yes") {
    Write-Host "❌ Sinkronisasi dibatalkan oleh pengguna." -ForegroundColor Red
    exit 0
}

# ─── STEP 1: DROP DATABASE LAMA DI LOKAL ──────────────────────────────────────
Write-Host "`n[1/2] 🗑️  Menghapus database lama '$DbName' di lokal..." -ForegroundColor Yellow

$dropQuery = "IF EXISTS (SELECT name FROM sys.databases WHERE name = N'$DbName') BEGIN ALTER DATABASE [$DbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DbName]; END"
$dropArgs = @(
    "exec", "common-mssql",
    "/opt/mssql-tools18/bin/sqlcmd",
    "-S", "localhost",
    "-U", "sa",
    "-P", $SaPassword,
    "-Q", $dropQuery,
    "-No", "-C"
)

$exitCode = Invoke-Docker -Label "Menghapus database '$DbName'" -DockerArgs $dropArgs

if ($exitCode -ne 0) {
    Write-Host "      ❌ Gagal menghapus database lama! Pastikan kontainer 'common-mssql' sedang berjalan." -ForegroundColor Red
    exit 1
}
Write-Host "      ✅ Database lama berhasil dibersihkan!" -ForegroundColor Green

# ─── STEP 2: JALANKAN RESTORE.SH DI KONTAINER ─────────────────────────────────
Write-Host "`n[2/2] 🔄 Memulai pemulihan database dari berkas backup..." -ForegroundColor Yellow

$restoreArgs = @(
    "exec", "common-mssql",
    "/bin/bash", "/restore.sh"
)

$exitCode = Invoke-Docker -Label "Merestore database '$DbName'" -DockerArgs $restoreArgs

if ($exitCode -ne 0) {
    Write-Host "      ❌ Pemulihan database gagal! Silakan periksa log kontainer." -ForegroundColor Red
    exit 1
}

Write-Host "      ✅ Pemulihan database berhasil!" -ForegroundColor Green

# ─── SELESAI ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 60) -ForegroundColor Cyan
Write-Host "  ✨ SINKRONISASI SQL SERVER SELESAI!" -ForegroundColor Cyan
Write-Host ("═" * 60) -ForegroundColor Cyan
