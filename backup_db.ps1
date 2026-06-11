#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script untuk backup database PostgreSQL dan meng-kompres hasilnya ke ZIP.
.DESCRIPTION
    Script ini menggunakan pg_dump via Docker untuk mengambil data dari server sumber
    dan mengompresnya menggunakan Compress-Archive (ZIP).
    Acuannya dari sync_posgres.ps1.
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

# --- KONFIGURASI SUMBER (SOURCE) ----------------------------------------------
$SourcePort = Get-Env -Key "PG_SOURCE_PORT" -Default "55321"
$SourceDb   = Get-Env -Key "PG_SOURCE_DB" -Default "phiro_multi_dev"
$SourceUser = Get-Env -Key "PG_SOURCE_USER" -Default "phirouser"
$SourcePass = Get-Env -Key "PG_SOURCE_PASS" -Default "PH1r0@ph1raka"

# --- SETUP FILE BACKUP --------------------------------------------------------
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir      = Join-Path $PSScriptRoot "backups"
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force }
$BaseName       = "backup_$($SourceDb)_$Timestamp"
$SqlFileName    = "$BaseName.sql"
$ZipFileName    = "$BaseName.zip"
$SqlFile        = Join-Path $BackupDir $SqlFileName
$ZipFile        = Join-Path $BackupDir $ZipFileName

# --- HELPER: Cleanup ----------------------------------------------------------
function Cleanup {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    if (Test-Path $SqlFile) {
        Remove-Item $SqlFile -ErrorAction SilentlyContinue
        Write-Host "  [DEL] File SQL sementara telah dihapus." -ForegroundColor Gray
    }
}

# --- HELPER: Run Docker dengan Spinner ----------------------------------------
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

    Write-Host -NoNewline "`r"
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

# ==============================================================================
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host " [BACKUP] POSTGRESQL DB BACKUP & ZIP" -ForegroundColor Cyan
Write-Host " Source: 127.0.0.1:${SourcePort} ($SourceDb)"
Write-Host " Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("=" * 60) -ForegroundColor Cyan

# --- STEP 1: BACKUP DARI SUMBER -----------------------------------------------
Write-Host "`n[1/2] Mengambil backup dari server sumber..." -ForegroundColor Yellow
Write-Host "      File: $SqlFile"

$dumpArgs = @(
    "run", "--rm",
    "-v", "${BackupDir}:/backup",
    "-e", "PGPASSWORD=$SourcePass",
    "postgres:18-alpine",
    "pg_dump",
    "--host=host.docker.internal",
    "--port=$SourcePort",
    "--username=$SourceUser",
    "--clean", "--if-exists", "--no-owner", "--no-privileges",
    "--format=p",
    "--file=/backup/$SqlFileName",
    $SourceDb
)

$exitCode = Invoke-Docker -Label "Menjalankan pg_dump" -DockerArgs $dumpArgs

if ($exitCode -ne 0) {
    Write-Host "      [FAIL] Gagal mengambil backup! (exit code: $exitCode)" -ForegroundColor Red
    Cleanup
    exit 1
}
Write-Host "      [OK] Backup SQL berhasil!" -ForegroundColor Green

# --- OPTIONAL: Membersihkan parameter v18 (agar kompatibel jika di-restore) ---
Write-Host "      [CLEAN] Membersihkan parameter v18..." -ForegroundColor Gray
$content = Get-Content -Path $SqlFile -Raw -Encoding UTF8
$content = $content -replace "(?m)^SET transaction_timeout = 0;", "-- SET transaction_timeout = 0;"
$content | Set-Content -Path $SqlFile -Encoding UTF8 -NoNewline

# --- STEP 2: KOMPRESI KE ZIP --------------------------------------------------
Write-Host "`n[2/2] Mengompres file ke ZIP..." -ForegroundColor Yellow
Write-Host "      Target: $ZipFile"

try {
    if (-not (Test-Path $SqlFile)) {
        throw "File SQL tidak ditemukan untuk dikompres."
    }

    Compress-Archive -Path $SqlFile -DestinationPath $ZipFile -Force
    Write-Host "      [OK] Kompresi berhasil!" -ForegroundColor Green
} catch {
    Write-Host "      [FAIL] Gagal mengompres file! Error: $($_.Exception.Message)" -ForegroundColor Red
    Cleanup
    exit 1
}

# --- SELESAI ------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  [DONE] BACKUP SELESAI!" -ForegroundColor Cyan
Write-Host "  [FILE] Result: $ZipFileName" -ForegroundColor White
Write-Host "  [SIZE] $((Get-Item $ZipFile).Length / 1MB -as [int]) MB" -ForegroundColor Gray
Cleanup
Write-Host ("=" * 60) -ForegroundColor Cyan
