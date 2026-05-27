#!/bin/bash
#
# setup.sh — All-in-One Moodle Migration
# 3.10 → 3.11 → 4.1 → 4.5 LTS
# Nutzung: sudo bash setup.sh
#

set -eo pipefail

# ============================================================
# Farben + Helpers
# ============================================================
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FEHLER]${NC} $1" >&2; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ============================================================
# Echter User — funktioniert mit UND ohne sudo
# ============================================================
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo "============================================"
echo "  Moodle Migration — All-in-One"
echo "  3.10 -> 3.11 -> 4.1 -> 4.5 LTS"
echo "  User: $REAL_USER | Home: $REAL_HOME"
echo "============================================"
echo ""

# ============================================================
# Pfade & Passwörter
# ============================================================
BASE="$REAL_HOME/moodle-migration"
REPO="$REAL_HOME/moodle-migration-repo"
BACKUPS="$BASE/backups"
SRC="$BASE/transit/moodle-src"
TRANSIT_ENV="$BASE/transit/.env"
TRANSIT_ROOT="transitroot123"

# ============================================================
# Hilfsfunktion: Neue config.php schreiben
# ============================================================
write_config() {
    local CONTAINER="$1"
    local PORT="$2"
    local TMPFILE
    TMPFILE=$(mktemp /tmp/moodle_config_XXXXXX.php)

    cat > "$TMPFILE" << 'PHPEOF'
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = 'mysqli';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'DBHOST_PH';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'root';
$CFG->dbpass    = 'DBPASS_PH';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = array(
    'dbpersist' => 0,
    'dbport'    => '',
    'dbsocket'  => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);
$CFG->wwwroot   = 'WWWROOT_PH';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;
require_once(__DIR__ . '/lib/setup.php');
PHPEOF

    sed -i "s|DBHOST_PH|moodle_db|g"                "$TMPFILE"
    sed -i "s|DBPASS_PH|${TRANSIT_ROOT}|g"           "$TMPFILE"
    sed -i "s|WWWROOT_PH|http://localhost:${PORT}|g" "$TMPFILE"

    docker cp "$TMPFILE" "$CONTAINER:/var/www/html/config.php"
    rm -f "$TMPFILE"
    ok "  config.php gesetzt (Port $PORT)"
}

# ============================================================
# Hilfsfunktion: DB + moodledata einspielen
# ============================================================
do_restore() {
    local DB_DUMP="$1"
    local MOODLE_TAR="$2"
    local DB_CONTAINER="$3"
    local VOLUME="$4"

    [[ -f "$DB_DUMP" ]]    || fail "DB-Dump nicht gefunden: $DB_DUMP"
    [[ -f "$MOODLE_TAR" ]] || fail "moodledata nicht gefunden: $MOODLE_TAR"

    info "  -> DB einspielen in $DB_CONTAINER..."
    zcat "$DB_DUMP" | docker exec -i \
        -e MYSQL_PWD="$TRANSIT_ROOT" \
        "$DB_CONTAINER" \
        mysql -u root

    info "  -> moodledata ins Volume $VOLUME..."
    docker run --rm \
        -v "${VOLUME}:/restore" \
        alpine:latest \
        sh -c "rm -rf /restore/* 2>/dev/null || true"

    docker run --rm \
        -v "${VOLUME}:/restore" \
        -v "$(realpath "$MOODLE_TAR"):/backup.tar.gz:ro" \
        alpine:latest \
        sh -c "tar -xzf /backup.tar.gz -C /restore --strip-components=1"

    info "  -> Ownership setzen (www-data 33:33)..."
    docker run --rm \
        -v "${VOLUME}:/restore" \
        alpine:latest \
        chown -R 33:33 /restore
}

# ============================================================
# Hilfsfunktion: PHP-Extensions installieren
# ============================================================
install_php_ext() {
    local CONTAINER="$1"
    info "  -> PHP-Extensions installieren..."
    docker exec "$CONTAINER" apt-get update -qq 2>/dev/null
    docker exec "$CONTAINER" apt-get install -y -qq \
        libzip-dev libpng-dev libicu-dev libxml2-dev libonig-dev 2>/dev/null
    docker exec "$CONTAINER" \
        docker-php-ext-install mysqli zip gd intl xml soap 2>/dev/null
    docker restart "$CONTAINER"
    sleep 20
    ok "  PHP-Extensions bereit"
}

# ============================================================
# Hilfsfunktion: Warte auf healthy
# ============================================================
wait_healthy() {
    local CONTAINER="$1"
    info "  -> Warte auf $CONTAINER..."
    for i in $(seq 1 60); do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "none")
        if [[ "$STATUS" == "healthy" ]]; then
            ok "  $CONTAINER ist bereit"
            return 0
        fi
        sleep 5
    done
    fail "$CONTAINER nicht healthy nach 5 Min"
}

# ============================================================
# Hilfsfunktion: Warte bis Bitnami KOMPLETT fertig ist
# Bitnami schreibt "Moodle installation completed" wenn wirklich alles fertig ist
# ============================================================
wait_bitnami_ready() {
    info "  -> Warte bis Bitnami komplett initialisiert (~10-15 Min)..."
    info "     (Bitnami installiert Moodle komplett neu bevor wir Daten einspielen)"
    for i in $(seq 1 300); do
        if docker logs prod-moodle_app 2>&1 | grep -q "Moodle setup finished"; then
            ok "  Bitnami ist fertig"
            return 0
        fi
        # Fortschritt anzeigen
        if (( i % 12 == 0 )); then
            MINS=$(( i * 5 / 60 ))
            info "  ... noch lädt ($MINS Min vergangen)"
        fi
        sleep 5
    done
    # Falls "Moodle installation completed" nicht erscheint,
    # prüfen ob Apache läuft als Fallback
    if docker logs prod-moodle_app 2>&1 | grep -q "Starting Apache"; then
        info "  Bitnami Apache läuft — warte noch 60s für DB-Init..."
        sleep 60
        ok "  Bitnami bereit (via Fallback)"
        return 0
    fi
    fail "Bitnami nicht bereit nach 25 Min"
}

# ============================================================
# SCHRITT 1: Ordner + Files + .env
# ============================================================
info "Schritt 1/8: Vorbereitung..."

[[ -d "$REPO" ]] || fail "Repo nicht gefunden: $REPO\nBitte:\ngit clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git $REPO"

mkdir -p "$BACKUPS" "$SRC" "$BASE/transit" "$BASE/prod" "$BASE/scripts"

cp "$REPO/transit/docker-compose.3.10.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.3.11.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.4.1.yml"  "$BASE/transit/"
cp "$REPO/prod/docker-compose.yml"          "$BASE/prod/"

chown -R "$REAL_USER:$REAL_USER" "$BASE"

cat > "$TRANSIT_ENV" << EOF
MYSQL_ROOT_PASSWORD=${TRANSIT_ROOT}
MYSQL_DATABASE=moodle
MYSQL_USER=moodle
MYSQL_PASSWORD=transitpass123
EOF

cat > "$BASE/prod/.env" << EOF
MYSQL_ROOT_PASSWORD=prodroot_changeme
MYSQL_DATABASE=moodle
MYSQL_USER=moodle
MYSQL_PASSWORD=prodpass_changeme
MOODLE_USERNAME=admin
MOODLE_PASSWORD=Admin1234!
MOODLE_EMAIL=admin@moodle.local
EOF

ok "Vorbereitung abgeschlossen"

# ============================================================
# SCHRITT 2: Backup
# ============================================================
info "Schritt 2/8: Backup vom Altsystem..."

[[ -f /var/www/html/config.php ]] || fail "/var/www/html/config.php nicht gefunden"
[[ -f /etc/mysql/debian.cnf ]]    || fail "/etc/mysql/debian.cnf nicht gefunden"

DB_DUMP=$(ls -t "$BACKUPS"/moodle_db_*.sql.gz 2>/dev/null | head -1 || true)
MOODLE_TAR=$(ls -t "$BACKUPS"/moodledata_*.tar.gz 2>/dev/null | head -1 || true)

if [[ -f "$DB_DUMP" && -f "$MOODLE_TAR" ]]; then
    info "  Backup bereits vorhanden — überspringe"
    ok "Backup: $(basename "$DB_DUMP")"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DB_DUMP="$BACKUPS/moodle_db_${TIMESTAMP}.sql.gz"
    MOODLE_TAR="$BACKUPS/moodledata_${TIMESTAMP}.tar.gz"

    mysqldump \
        --defaults-file=/etc/mysql/debian.cnf \
        --single-transaction --routines --triggers --events \
        --databases moodle \
        | gzip > "$DB_DUMP"

    tar -czf "$MOODLE_TAR" -C /var/www moodledata
    chown "$REAL_USER:$REAL_USER" "$DB_DUMP" "$MOODLE_TAR"
    ok "Backup: $(basename "$DB_DUMP")"
fi

# ============================================================
# SCHRITT 3: Moodle Sources
# ============================================================
info "Schritt 3/8: Moodle-Sources vorbereiten..."
cd "$SRC"

if [[ ! -d "moodle-3.10" ]]; then
    mkdir -p moodle-3.10
    cp -r /var/www/html/. moodle-3.10/
    chown -R "$REAL_USER:$REAL_USER" moodle-3.10/
    ok "  moodle-3.10 kopiert"
fi

if [[ ! -f "moodle-3.11.18.tgz" ]]; then
    wget -q --show-progress -O moodle-3.11.18.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v3.11.18.tar.gz"
fi

if [[ ! -f "moodle-4.1.17.tgz" ]]; then
    wget -q --show-progress -O moodle-4.1.17.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v4.1.17.tar.gz"
fi

if [[ ! -d "moodle-3.11.18" ]]; then
    tar -xzf moodle-3.11.18.tgz -C .
    if [[ ! -d "moodle-3.11.18" ]]; then
        UNPACKED=$(find . -maxdepth 1 -type d -name "moodle-*3.11*" | head -1 || true)
        [[ -n "$UNPACKED" ]] && mv "$UNPACKED" moodle-3.11.18
    fi
    [[ -d "moodle-3.11.18" ]] || fail "moodle-3.11.18 konnte nicht entpackt werden"
fi

if [[ ! -d "moodle-4.1.17" ]]; then
    tar -xzf moodle-4.1.17.tgz -C .
    if [[ ! -d "moodle-4.1.17" ]]; then
        UNPACKED=$(find . -maxdepth 1 -type d -name "moodle-*4.1*" | head -1 || true)
        [[ -n "$UNPACKED" ]] && mv "$UNPACKED" moodle-4.1.17
    fi
    [[ -d "moodle-4.1.17" ]] || fail "moodle-4.1.17 konnte nicht entpackt werden"
fi

ok "Sources bereit"

# ============================================================
# SCHRITT 4: Transit 3.10
# ============================================================
info "Schritt 4/8: Transit-Stack 3.10 starten..."
cd "$BASE/transit"

docker compose -p transit310 -f docker-compose.3.10.yml up -d
wait_healthy transit310-moodle_db

do_restore "$DB_DUMP" "$MOODLE_TAR" "transit310-moodle_db" "transit310_moodledata"
write_config "transit310-moodle_app" "8090"
install_php_ext "transit310-moodle_app"
ok "Transit 3.10 bereit"

# ============================================================
# SCHRITT 5: Upgrade 3.10 → 3.11
# ============================================================
info "Schritt 5/8: Upgrade 3.10 -> 3.11..."
cd "$BASE/transit"

docker compose -p transit310 -f docker-compose.3.10.yml down
docker compose -p transit311 -f docker-compose.3.11.yml up -d
wait_healthy transit311-moodle_db

do_restore "$DB_DUMP" "$MOODLE_TAR" "transit311-moodle_db" "transit311_moodledata"
write_config "transit311-moodle_app" "8091"
install_php_ext "transit311-moodle_app"

docker exec transit311-moodle_app \
    php /var/www/html/admin/cli/upgrade.php --non-interactive
ok "3.11 Upgrade abgeschlossen"

# ============================================================
# SCHRITT 6: DB-Snapshot 3.11
# ============================================================
info "Schritt 6/8: DB-Snapshot nach 3.11..."
docker exec \
    -e MYSQL_PWD="$TRANSIT_ROOT" \
    transit311-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_3.11_ready.sql.gz"
chown "$REAL_USER:$REAL_USER" "$BACKUPS/moodle_3.11_ready.sql.gz"
ok "Snapshot: moodle_3.11_ready.sql.gz"

# ============================================================
# SCHRITT 7: Upgrade 3.11 → 4.1
# ============================================================
info "Schritt 7/8: Upgrade 3.11 -> 4.1..."
cd "$BASE/transit"

docker compose -p transit311 -f docker-compose.3.11.yml down
docker compose -p transit41  -f docker-compose.4.1.yml up -d
wait_healthy transit41-moodle_db

do_restore "$BACKUPS/moodle_3.11_ready.sql.gz" "$MOODLE_TAR" \
    "transit41-moodle_db" "transit41_moodledata"
write_config "transit41-moodle_app" "8092"
install_php_ext "transit41-moodle_app"

docker exec transit41-moodle_app sh -c \
    'echo "max_input_vars = 5000" > /usr/local/etc/php/conf.d/moodle.ini'
docker restart transit41-moodle_app
sleep 20

docker exec transit41-moodle_app \
    php /var/www/html/admin/cli/upgrade.php --non-interactive
ok "4.1 Upgrade abgeschlossen"

# ============================================================
# SCHRITT 8: Prod-Stack (4.5 LTS)
# ============================================================
info "Schritt 8/8: Prod-Stack mit Moodle 4.5 LTS..."

# DB-Snapshot aus 4.1
docker exec \
    -e MYSQL_PWD="$TRANSIT_ROOT" \
    transit41-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_4.1_ready.sql.gz"
chown "$REAL_USER:$REAL_USER" "$BACKUPS/moodle_4.1_ready.sql.gz"
ok "Snapshot: moodle_4.1_ready.sql.gz"

# Apache stoppen damit Port 80 frei ist
info "  -> Apache stoppen (braucht Port 80)..."
systemctl stop apache2 2>/dev/null || true

# Image holen
docker pull bitnamilegacy/moodle:4.5

# Alte Prod-Container + Volumes komplett löschen (sauber starten)
info "  -> Alte Prod-Volumes löschen (sauber starten)..."
docker compose -p prod -f "$BASE/prod/docker-compose.yml" down -v 2>/dev/null || true

# Prod starten
cd "$BASE/prod"
docker compose -p prod up -d

# *** WICHTIG: Warten bis Bitnami KOMPLETT fertig ist ***
# Bitnami initialisiert Moodle komplett selbst — erst danach überschreiben wir die DB
wait_bitnami_ready

# DB komplett überschreiben mit unseren 4.1-Daten
info "  -> DB mit migrierten Daten überschreiben..."
docker exec \
    -e MYSQL_PWD=prodroot_changeme \
    prod-moodle_db mysql -u root \
    -e "DROP DATABASE IF EXISTS moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

zcat "$BACKUPS/moodle_4.1_ready.sql.gz" \
    | docker exec -i \
        -e MYSQL_PWD=prodroot_changeme \
        prod-moodle_db mysql -u root moodle

# Ownership für Bitnami
docker run --rm \
    -v prod_moodledata:/restore \
    alpine:latest \
    chown -R 1001:1 /restore

# Collation fixen
docker exec prod-moodle_app sed -i \
    "s|utf8mb4_0900_ai_ci|utf8mb4_unicode_ci|g" /bitnami/moodle/config.php

# Upgrade auf 4.5
info "  -> Upgrade auf 4.5..."
docker exec prod-moodle_app \
    php /opt/bitnami/moodle/admin/cli/upgrade.php --non-interactive

# Container neu starten damit alles sauber lädt
docker restart prod-moodle_app
sleep 30

ok "Prod-Stack fertig"

# ============================================================
# Fertig
# ============================================================
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80 2>/dev/null || echo "000")

echo ""
echo "============================================"
echo "  Migration abgeschlossen!"
echo "============================================"
echo ""
if [[ "$HTTP" == "200" || "$HTTP" == "303" ]]; then
    ok "Moodle laeuft auf http://localhost:80 (HTTP $HTTP)"
else
    info "HTTP $HTTP — evtl. noch 1-2 Min warten"
fi
echo ""
echo "  Login:  admin / Admin1234!"
echo ""
echo "  Passwort zuruecksetzen falls noetig:"
echo "  docker exec -it prod-moodle_app \\"
echo "    php /opt/bitnami/moodle/admin/cli/reset_password.php"
echo ""
