# Moodle Migration 3.10 → 4.5 LTS

Automated migration pipeline from Moodle 3.10 to 4.5 LTS via Docker.
Moodle requires sequential upgrades — direct jumps across major versions are not supported.

**Upgrade path:** `3.10 → 3.11 → 4.1 → 4.5 LTS`

**Team:** Noah Kronhardt, Robin Weder, Nico Bischof — GBS St.Gallen (M158/M169)

---

## Prerequisites

- Ubuntu 22.04 (or compatible)
- Docker Engine 20.10+ with Compose v2 (`docker compose` not `docker-compose`)
- Running Moodle 3.10 source at `/var/www/html` and data at `/var/www/moodledata`
- MySQL accessible via `/etc/mysql/debian.cnf`
- ~10 GB free disk space
- Internet access for `docker pull`

---

## Usage

```bash
git clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git ~/moodle-migration-repo
sudo bash ~/moodle-migration-repo/scripts/setup.sh
```

The script is fully automated and idempotent — existing backups and downloaded sources are reused on re-runs. When it completes, Moodle 4.5 LTS is running at **http://localhost**.

> **Note:** Initial run takes 20–40 minutes. Bitnami initializes a fresh Moodle instance internally before the migrated data is imported.

---

## What `setup.sh` does

| Step | Description |
|------|-------------|
| 1 | Creates working directories, writes `.env` files, copies compose configs |
| 2 | Backs up the existing Moodle DB and moodledata (skipped if backup already exists) |
| 3 | Downloads Moodle 3.11.18 and 4.1.17 sources, creates version symlinks |
| 4 | Starts transit310 stack, restores backup, installs PHP extensions |
| 5 | Upgrades to 3.11: restarts with transit311, restores data, runs `upgrade.php` |
| 6 | Snapshots the 3.11 DB |
| 7 | Upgrades to 4.1: restarts with transit41, restores 3.11 snapshot, runs `upgrade.php` |
| 8 | Starts Bitnami 4.5 prod stack, imports migrated DB + moodledata, upgrades to 4.5 |

Transit stacks are torn down with `--volumes` after each stage to guarantee clean MySQL initialization on re-runs.

---

## Configuration

Passwords and settings are defined at the top of `setup.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TRANSIT_ROOT` | `transitroot123` | MySQL root password for all transit stacks |
| `BASE` | `~/moodle-migration` | Working directory |
| `REPO` | `~/moodle-migration-repo` | This repository |

Prod stack credentials are written to `$BASE/prod/.env` during step 1. Change them in `setup.sh` before running if needed:

```bash
MYSQL_ROOT_PASSWORD=prodroot_changeme
MYSQL_PASSWORD=prodpass_changeme
MOODLE_PASSWORD=Admin1234!
```

---

## Repository structure

```
.
├── scripts/
│   └── setup.sh              # Main migration script
├── transit/
│   ├── docker-compose.3.10.yml
│   ├── docker-compose.3.11.yml
│   └── docker-compose.4.1.yml
└── prod/
    └── docker-compose.yml    # Bitnami Moodle 4.5 LTS
```

Transit stacks mount Moodle sources from `$BASE/transit/moodle-src/` and use named volumes (`transit310_*`, `transit311_*`, `transit41_*`). The prod stack uses `bitnamilegacy/moodle:4.5`.

---

## Troubleshooting

**Migration fails midway — can I re-run?**  
Yes. The script skips existing backups and downloaded sources. All transit stacks are cleaned up with `down -v` before each stage, so stale volumes don't cause issues.

**`ERROR 1045 (28000): Access denied for user 'root'`**  
Caused by leftover MySQL volumes from a previous failed run. Fixed in the current version — transit stacks are always started with fresh volumes.

**HTTP 500 after prod start**  
Usually a permissions issue on `/bitnami/moodledata`. The Bitnami container must run as `daemon` (uid=1). Do not manually `chown` to uid 1001 — Bitnami sets permissions itself on startup.

**`bitnami/moodle:4.5` not found**  
The image was moved to `bitnamilegacy/moodle:4.5`. The compose file already references the correct image.

**Old Moodle still needed on port 8080**  
The script stops Apache to free port 80. To run the old installation in parallel:
```bash
sudo sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf
sudo systemctl start apache2
```
