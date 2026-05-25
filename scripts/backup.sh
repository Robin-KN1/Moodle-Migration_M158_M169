#!/bin/bash
#
# restore.sh — spielt Moodle-Backup in einen laufenden Docker-Stack zurück.
#
# Nutzung:
#   sudo bash restore.sh <db-dump.sql.gz> <moodledata.tar.gz> [stack-prefix]
#
# Beispiel:
#   sudo bash restore.sh \
#     ~/moodle-migration/backups/moodle_db_20260513_141059.sql.gz \
#     ~/moodle-migration/backups/moodledata_20260513_141059.tar.gz \
#     transit
#
# Voraussetzungen:
#   - Container moodle_db und moodle_app laufen (docker compose up -d)
#   - .env mit MYSQL_ROOT_PASSWORD existiert im Stack-Verzeichnis
#

set -euo pipefail

# ========== Argumente ==========
if [[ $# -lt 2 ]]; then
    echo "Nutzung: $0 <db-dump.sql.gz> <moodledata.tar.gz> [stack-prefix]" >&2
    echo "" >&2
    echo "Beispiel:" >&2
    echo "  $0 ../backups/moodle_db_*.sql.gz ../backups/moodledata_*.tar.gz transit" >&2
    exit 1
fi

DB_DUMP="$1"
MOODLEDATA_TAR="$2"
STACK_PREFIX="${3:-transit}"

# Container-Namen ableiten (Docker Compose hängt Prefix vorne dran)
DB_CONTAINER="${STACK_PREFIX}-moodle_db-1"
APP_CONTAINER="${STACK_PREFIX}-moodle_app-1"
MOODLEDATA_VOLUME="${STACK_PREFIX}_moodledata"

# .env-Datei aus dem Stack-Verzeichnis lesen
STACK_DIR="$HOME/moodle-migration/${STACK_PREFIX}"
ENV_FILE="${STACK_DIR}/.env"

# ========== Vorab-Checks ==========
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Bitte mit sudo ausführen." >&2
    exit 1
fi

[[ -f "$DB_DUMP" ]]        || { echo "Fehler: DB-Dump nicht gefunden: $DB_DUMP" >&2; exit 1; }
[[ -f "$MOODLEDATA_TAR" ]] || { echo "Fehler: moodledata-Archiv nicht gefunden: $MOODLEDATA_TAR" >&2; exit 1; }
[[ -f "$ENV_FILE" ]]       || { echo "Fehler: .env nicht gefunden: $ENV_FILE" >&2; exit 1; }

# MYSQL_ROOT_PASSWORD aus .env lesen
MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
[[ -n "$MYSQL_ROOT_PASSWORD" ]] || { echo "Fehler: MYSQL_ROOT_PASSWORD ist leer in $ENV_FILE" >&2; exit 1; }

# Container prüfen
docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"  || { echo "Fehler: Container $DB_CONTAINER läuft nicht" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -q "^${APP_CONTAINER}$" || { echo "Fehler: Container $APP_CONTAINER läuft nicht" >&2; exit 1; }

echo "=== Moodle-Restore gestartet: $(date) ==="
echo "DB-Dump:        $DB_DUMP"
echo "moodledata:     $MOODLEDATA_TAR"
echo "Stack-Prefix:   $STACK_PREFIX"
echo "DB-Container:   $DB_CONTAINER"
echo "App-Container:  $APP_CONTAINER"

# ========== Schritt 1: Checksum prüfen (falls Datei vorhanden) ==========
echo ""
echo "[1/5] Checksums prüfen..."
CHECKSUM_FILE=$(dirname "$DB_DUMP")/checksums_$(basename "$DB_DUMP" | sed 's/moodle_db_//;s/.sql.gz//').txt
if [[ -f "$CHECKSUM_FILE" ]]; then
    (
        cd "$(dirname "$DB_DUMP")"
        sha256sum -c "$(basename "$CHECKSUM_FILE")"
    )
else
    echo "      Hinweis: Kein Checksum-File gefunden ($CHECKSUM_FILE) — überspringe."
fi

# ========== Schritt 2: DB einspielen ==========
echo ""
echo "[2/5] DB-Dump in Container $DB_CONTAINER einspielen..."
# zcat entpackt SQL-Dump, pipe direkt in mysql im Container
# -i (interactive) damit STDIN durchgereicht wird
zcat "$DB_DUMP" | docker exec -i \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    "$DB_CONTAINER" \
    mysql -u root
echo "      DB-Import abgeschlossen."

# ========== Schritt 3: moodledata ins Volume entpacken ==========
echo ""
echo "[3/5] moodledata ins Volume $MOODLEDATA_VOLUME entpacken..."

# Volume mounten in einen Hilfs-Container, tar darin auspacken.
# Wir nutzen alpine:latest weil minimal und schnell.
# Achtung: tar-Archiv hat moodledata/... als Top-Level — wir mounten direkt
# in /restore und entpacken mit --strip-components=1, damit der Inhalt
# direkt ins Volume-Root landet (nicht in /restore/moodledata).
docker run --rm \
    -v "${MOODLEDATA_VOLUME}:/restore" \
    -v "$(realpath "$MOODLEDATA_TAR"):/backup.tar.gz:ro" \
    alpine:latest \
    sh -c "rm -rf /restore/* /restore/.[!.]* 2>/dev/null; tar -xzf /backup.tar.gz -C /restore --strip-components=1"
echo "      moodledata wiederhergestellt."

# ========== Schritt 4: Berechtigungen setzen ==========
echo ""
echo "[4/5] Berechtigungen im moodledata setzen..."
# Bitnami-Moodle-Container nutzt User 1001:0 (daemon).
# Klassisches Apache-Image (php:7.4-apache) nutzt www-data (33:33).
# Wir setzen je nach App-Container-Image den richtigen Owner.
APP_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$APP_CONTAINER")
if [[ "$APP_IMAGE" == *"bitnami"* ]]; then
    OWNER="1001:0"
    echo "      Erkannt: Bitnami-Image → Owner $OWNER"
else
    OWNER="33:33"
    echo "      Erkannt: Standard PHP/Apache → Owner $OWNER (www-data)"
fi

docker run --rm \
    -v "${MOODLEDATA_VOLUME}:/restore" \
    alpine:latest \
    chown -R "$OWNER" /restore
echo "      Ownership gesetzt auf $OWNER."

# ========== Schritt 5: Verifikation ==========
echo ""
echo "[5/5] Verifikation..."

# DB: Zeilen-Counts der wichtigsten Tabellen
echo ""
echo "      DB-Tabellen (Zeilen-Counts):"
docker exec \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    "$DB_CONTAINER" \
    mysql -u root -N -B -e "
        SELECT 'mdl_user'         AS tabelle, COUNT(*) AS anzahl FROM moodle.mdl_user
        UNION SELECT 'mdl_course',           COUNT(*) FROM moodle.mdl_course
        UNION SELECT 'mdl_course_modules',   COUNT(*) FROM moodle.mdl_course_modules
        UNION SELECT 'mdl_files',            COUNT(*) FROM moodle.mdl_files
        UNION SELECT 'mdl_role_assignments', COUNT(*) FROM moodle.mdl_role_assignments;
    " | column -t

# Volume: Dateien gezählt
echo ""
echo "      moodledata-Volume (Anzahl Dateien in filedir):"
FILE_COUNT=$(docker run --rm -v "${MOODLEDATA_VOLUME}:/m:ro" alpine:latest \
    sh -c "find /m/filedir -type f 2>/dev/null | wc -l")
echo "      filedir: $FILE_COUNT Dateien"

echo ""
echo "=== Restore abgeschlossen: $(date) ==="
echo ""
echo "Nächster Schritt:"
echo "  - Browser öffnen auf http://localhost:<port-deines-stacks>"
echo "  - Login mit Admin-Account testen"
echo "  - Falls Moodle nach Upgrade fragt: das ist normal bei Major-Version-Wechsel"
