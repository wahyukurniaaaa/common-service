#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script untuk backup database SQL Server (MSSQL) dan meng-kompres hasilnya ke ZIP.
.DESCRIPTION
    Script ini melakukan BACKUP DATABASE di dalam kontainer Docker mssql
    dan mengekspor serta mengompres berkas hasil backup ke format ZIP.
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

if (-not $DbName -or -not $SaPassword) {
    Write-Host "❌ Konfigurasi SQL Server di .env tidak lengkap! Pastikan MSSQL_DB dan MSSQL_PASSWORD terisi." -ForegroundColor Red
    exit 1
}

# ─── SETUP FILE BACKUP ────────────────────────────────────────────────────────
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir      = Join-Path $PSScriptRoot "backups"
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force }

$BaseName       = "backup_mssql_$($DbName)_$Timestamp"
$BakFileName    = "$BaseName.bak"
$ZipFileName    = "$BaseName.zip"
$HostBakFile    = Join-Path $BackupDir $BakFileName
$HostZipFile    = Join-Path $BackupDir $ZipFileName

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

    $frames  = @("|","/","-","\\")
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
            if ($line) { Write-Host "      >> $line" -ForegroundColor DarkGray }
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
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host " [BACKUP] SQL SERVER DB BACKUP & ZIP" -ForegroundColor Cyan
Write-Host " Target Container: common-mssql"
Write-Host " Target Database : $DbName"
Write-Host " Time            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("=" * 60) -ForegroundColor Cyan

# ─── STEP 1: EXPORT BACKUP DI DALAM KONTAINER ─────────────────────────────────
Write-Host "`n[1/3] 📥 Membuat file backup (.bak) di dalam kontainer..." -ForegroundColor Yellow

$backupQuery = "BACKUP DATABASE [$DbName] TO DISK = N'/var/opt/mssql/backup/$BakFileName' WITH FORMAT, COPY_ONLY, STATS = 10"
$backupArgs = @(
    "exec", "common-mssql",
    "/opt/mssql-tools18/bin/sqlcmd",
    "-S", "localhost",
    "-U", "sa",
    "-P", $SaPassword,
    "-Q", $backupQuery,
    "-No", "-C"
)

$exitCode = Invoke-Docker -Label "Menjalankan BACKUP DATABASE" -DockerArgs $backupArgs

if ($exitCode -ne 0) {
    Write-Host "      ❌ Gagal membuat backup di kontainer! Pastikan kontainer 'common-mssql' sedang berjalan." -ForegroundColor Red
    exit 1
}
Write-Host "      ✅ Backup SQL Server berhasil dibuat di dalam kontainer!" -ForegroundColor Green

# ─── STEP 2: COPY DARI KONTAINER KE HOST ──────────────────────────────────────
Write-Host "`n[2/3] 📂 Menyalin file backup dari kontainer ke komputer host..." -ForegroundColor Yellow

$copyArgs = @(
    "cp",
    "common-mssql:/var/opt/mssql/backup/$BakFileName",
    $HostBakFile
)

$exitCode = Invoke-Docker -Label "Menyalin file backup" -DockerArgs $copyArgs

# Hapus file sementara di dalam kontainer agar menghemat disk space kontainer
$cleanupArgs = @(
    "exec", "common-mssql",
    "rm", "-f", "/var/opt/mssql/backup/$BakFileName"
)
Invoke-Docker -Label "Membersihkan berkas sementara di kontainer" -DockerArgs $cleanupArgs | Out-Null

if ($exitCode -ne 0) {
    Write-Host "      ❌ Gagal menyalin file backup ke host!" -ForegroundColor Red
    exit 1
}
Write-Host "      ✅ File backup berhasil disalin ke $HostBakFile!" -ForegroundColor Green

# ─── STEP 3: KOMPRESI KE ZIP ──────────────────────────────────────────────────
Write-Host "`n[3/3] 🤐 Mengompres file backup ke ZIP..." -ForegroundColor Yellow
Write-Host "      Target: $HostZipFile"

try {
    if (-not (Test-Path $HostBakFile)) {
        throw "File .bak tidak ditemukan untuk dikompres."
    }

    Compress-Archive -Path $HostBakFile -DestinationPath $HostZipFile -Force
    Write-Host "      ✅ Kompresi ZIP berhasil!" -ForegroundColor Green
} catch {
    Write-Host "      ❌ Gagal mengompres file! Error: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path $HostBakFile) { Remove-Item $HostBakFile -Force }
    exit 1
}

# Hapus file .bak sementara di host
if (Test-Path $HostBakFile) { Remove-Item $HostBakFile -Force }

# ─── SELESAI ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  🎉 BACKUP SQL SERVER SELESAI!" -ForegroundColor Cyan
Write-Host "  [FILE] Hasil : $ZipFileName" -ForegroundColor White
Write-Host "  [SIZE] Ukuran: $((Get-Item $HostZipFile).Length / 1MB -as [int]) MB" -ForegroundColor Gray
Write-Host ("=" * 60) -ForegroundColor Cyan
