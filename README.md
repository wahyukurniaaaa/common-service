# 🌐 General Database Services (MSSQL & PostgreSQL)

Repositori ini menyediakan infrastruktur database **general-purpose** berbasis Docker Compose yang berkinerja tinggi, aman, dan tangguh untuk lingkungan pengembangan lokal (*local development*). 

Dilengkapi dengan sistem **Auto-Restore & Sync** dinamis untuk menyinkronkan data dari server pusat langsung melalui jaringan (*direct network pull*), serta skrip otomasi cadangan (*backup & restore*) interaktif menggunakan PowerShell.

---

## ✨ Fitur Utama

1. **🚀 Native WSL2 Performance (Named Volumes)**:
   * Penyimpanan database di-mount menggunakan **Docker Named Volumes** (`postgres_data` & `mssql_data`) di dalam filesystem ext4 WSL2.
   * Waktu startup database berkurang drastis (di bawah 1 detik) dan terbebas dari masalah data hilang/korup akibat PC mati mendadak (*ungraceful shutdown*).
2. **🔄 Automatic Network Sync & Restore (Direct Pull)**:
   * **PostgreSQL**: Menggunakan `pg_dump | psql` untuk *direct stream* data dari server sumber ke lokal kontainer.
   * **SQL Server (MSSQL)**: Menggunakan Microsoft `sqlpackage` di dalam kontainer untuk melakukan ekspor `.bacpac` *live* dari server sumber ke lokal tanpa berkas fisik `.bak` manual.
3. **📁 Smart File Fallback**:
   * Jika tidak ada jaringan atau server sumber tidak terisi di `.env`, skrip akan otomatis beralih (*fallback*) mencari berkas `.zip` atau `.bak`/`.sql` di folder proyek untuk memulihkan data lokal secara otomatis.
4. **🎨 Interactive Automation Scripts**:
   * Skrip PowerShell interaktif lengkap dengan indikator proses (*spinner animation*) untuk mempermudah backup dan sync secara berkala.

---

## 📂 Struktur Repositori

```text
├── docker/
│   ├── mssql/
│   │   ├── entrypoint.sh      # Entrypoint kontainer SQL Server
│   │   └── restore.sh         # Skrip restore & pull SQL Server (sqlpackage)
│   └── postgres/
│       ├── entrypoint.sh      # Entrypoint kontainer PostgreSQL
│       └── restore.sh         # Skrip restore & pull PostgreSQL (pg_dump)
├── backups/                   # Direktori penyimpanan hasil backup (auto-generated)
├── docker-compose.yml         # Konfigurasi container service
├── sync_posgres.ps1           # Sinkronisasi manual PostgreSQL dari server
├── sync_mssql.ps1             # Sinkronisasi manual SQL Server dari server
├── backup_db.ps1              # Backup PostgreSQL lokal ke ZIP
├── backup_mssql.ps1           # Backup SQL Server lokal ke ZIP
├── generate_migration_sql.ps1 # Generator berkas migrasi SQL Server -> Postgres
├── .env.example               # Template konfigurasi environment
└── README.md                  # Dokumentasi repositori
```

---

## 🚀 Memulai Penggunaan

### 1. Prasyarat
* Docker Desktop terinstal dengan **WSL2 Integration** aktif.
* PowerShell 7+ (direkomendasikan untuk menjalankan skrip `.ps1` interaktif).

### 2. Setup Konfigurasi
Salin file `.env.example` menjadi `.env` di direktori utama proyek:
```bash
cp .env.example .env
```
Buka file `.env` dan sesuaikan kredensial target lokal serta server sumber pusat Anda.

### 3. Jalankan Kontainer Database
Jalankan perintah berikut di direktori utama:
```powershell
docker compose up -d
```
* **Alur otomatis**: Docker akan membuat kontainer `common-postgres` dan `common-mssql`. Pada startup pertama, jika volume data kosong, masing-masing database akan otomatis melakukan *direct pull* dari server sumber pusat dan mengisinya ke lokal kontainer Anda.

---

## 🛠️ Panduan Skrip Otomasi

Semua skrip di bawah dijalankan melalui terminal **PowerShell**:

### 🔄 Sinkronisasi Database (Sync)
Menghapus database lokal saat ini dan menarik data segar/terbaru dari server sumber secara langsung:
```powershell
# Sinkronisasi PostgreSQL
.\sync_posgres.ps1

# Sinkronisasi SQL Server (MSSQL)
.\sync_mssql.ps1
```

### 📥 Cadangan Database (Backup)
Membuat berkas backup dari database Docker lokal saat ini, mengekspornya, dan mengompresnya langsung ke format ZIP di dalam direktori `./backups/`:
```powershell
# Backup PostgreSQL lokal ke ZIP
.\backup_db.ps1

# Backup SQL Server lokal ke ZIP
.\backup_mssql.ps1
```

### ⚡ Migrasi Database (MSSQL ➔ Postgres)
Membuat berkas migrasi SQL INSERT yang kompatibel dengan PostgreSQL dari data SQL Server lokal Anda:
```powershell
.\generate_migration_sql.ps1
```

---

## 🔒 Keamanan Data
* File `.env` dan direktori `./backups/` telah terdaftar di `.gitignore` untuk mencegah kebocoran kredensial dan file database besar ke publik.
* Selalu pastikan kredensial server pusat aman di dalam berkas `.env` lokal Anda.
