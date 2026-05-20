#!/bin/bash
#
# backup.sh — sichert MySQL-DB und moodledata vom Moodle-Altsystem.
#
# Nutzung: sudo bash backup.sh
#

set -euo pipefail

# ========== Konfiguration ==========
BACKUP_DIR="/home/vmadmin/moodle-migration/backups"
MOODLEDATA_SRC="/var/www/moodledata"
DB_NAME="moodle"
DB_DEFAULTS="/etc/mysql/debian.cnf"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DB_DUMP="$BACKUP_DIR/moodle_db_${TIMESTAMP}.sql.gz"
MOODLEDATA_TAR="$BACKUP_DIR/moodledata_${TIMESTAMP}.tar.gz"
CHECKSUM_FILE="$BACKUP_DIR/checksums_${TIMESTAMP}.txt"

# ========== Vorab-Checks ==========
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Bitte mit sudo ausführen." >&2
    exit 1
fi

ORIG_USER="${SUDO_USER:-vmadmin}"

[[ -f "$DB_DEFAULTS" ]]    || { echo "Fehler: $DB_DEFAULTS fehlt" >&2; exit 1; }
[[ -d "$MOODLEDATA_SRC" ]] || { echo "Fehler: $MOODLEDATA_SRC fehlt" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"

echo "=== Moodle-Backup gestartet: $(date)x ==="
echo "Ziel-Verzeichnis: $BACKUP_DIR"

# ========== Schritt 1: MySQL-Dump ==========
echo ""
echo "[1/4] MySQL-Dump erstellen..."
mysqldump \
    --defaults-file="$DB_DEFAULTS" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --databases "$DB_NAME" \
    | gzip > "$DB_DUMP"
echo "      Erstellt: $DB_DUMP ($(du -h "$DB_DUMP" | cut -f1))"

# ========== Schritt 2: moodledata-Archiv ==========
echo ""
echo "[2/4] moodledata archivieren..."
tar -czf "$MOODLEDATA_TAR" -C /var/www moodledata
echo "      Erstellt: $MOODLEDATA_TAR ($(du -h "$MOODLEDATA_TAR" | cut -f1))"

# ========== Schritt 3: Checksums ==========
echo ""
echo "[3/4] SHA256-Checksums berechnen..."
(
    cd "$BACKUP_DIR"
    sha256sum \
        "$(basename "$DB_DUMP")" \
        "$(basename "$MOODLEDATA_TAR")" \
        > "$CHECKSUM_FILE"
)
cat "$CHECKSUM_FILE"

# ========== Schritt 4: Ownership ==========
echo ""
echo "[4/4] Ownership auf '$ORIG_USER' setzen..."
chown "$ORIG_USER:$ORIG_USER" "$DB_DUMP" "$MOODLEDATA_TAR" "$CHECKSUM_FILE"

echo ""
echo "=== Backup abgeschlossen: $(date) ==="
echo ""
ls -lh "$DB_DUMP" "$MOODLEDATA_TAR" "$CHECKSUM_FILE"