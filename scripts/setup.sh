#!/bin/bash
#
# setup.sh — All-in-One Moodle Migration
# Moodle 3.10 → 3.11 → 4.1 → 4.5 LTS
#
# Nutzung: sudo bash setup.sh
#

set -euo pipefail

# ============================================================
# Farben
# ============================================================
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FEHLER]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ============================================================
# Echter User — funktioniert mit UND ohne sudo
# ============================================================
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo "============================================"
echo "  Moodle Migration — All-in-One"
echo "  3.10 → 3.11 → 4.1 → 4.5 LTS"
echo "  User: $REAL_USER | Home: $REAL_HOME"
echo "============================================"
echo ""

# ============================================================
# Pfade
# ============================================================
BASE="$REAL_HOME/moodle-migration"
REPO="$REAL_HOME/moodle-migration-repo"
BACKUPS="$BASE/backups"
SRC="$BASE/transit/moodle-src"
TRANSIT_ENV="$BASE/transit/.env"

# Passwörter
TRANSIT_ROOT="transitroot123"
TRANSIT_DB="moodle"
TRANSIT_USER="moodle"
TRANSIT_PW="transitpass123"

# ============================================================
# Hilfsfunktion: DB + moodledata in Container einspielen
# (inline, kein restore.sh nötig)
# ============================================================
do_restore() {
    local DB_DUMP="$1"
    local MOODLE_TAR="$2"
    local DB_CONTAINER="$3"
    local APP_CONTAINER="$4"
    local VOLUME="$5"

    info "  → DB einspielen in $DB_CONTAINER..."
    zcat "$DB_DUMP" | docker exec -i \
        -e MYSQL_PWD="$TRANSIT_ROOT" \
        "$DB_CONTAINER" \
        mysql -u root

    info "  → moodledata ins Volume $VOLUME..."
    docker run --rm \
        -v "${VOLUME}:/restore" \
        -v "$(realpath "$MOODLE_TAR"):/backup.tar.gz:ro" \
        alpine:latest \
        sh -c "rm -rf /restore/* 2>/dev/null; tar -xzf /backup.tar.gz -C /restore --strip-components=1"

    info "  → Ownership setzen (www-data)..."
    docker run --rm \
        -v "${VOLUME}:/restore" \
        alpine:latest \
        chown -R 33:33 /restore
}

# ============================================================
# Hilfsfunktion: config.php in Container anpassen
# ============================================================
fix_config() {
    local CONTAINER="$1"
    local PORT="$2"
    local CONFIG_SRC="$3"

    docker cp "$CONFIG_SRC" "$CONTAINER:/var/www/html/config.php"
    docker exec "$CONTAINER" sed -i \
        "s/\$CFG->dbhost\s*=\s*'[^']*'/\$CFG->dbhost = 'moodle_db'/" \
        /var/www/html/config.php
    docker exec "$CONTAINER" sed -i \
        "s/\$CFG->dbuser\s*=\s*'[^']*'/\$CFG->dbuser = 'root'/" \
        /var/www/html/config.php
    docker exec "$CONTAINER" sed -i \
        "s|\$CFG->dbpass\s*=\s*'[^']*'|\$CFG->dbpass = '$TRANSIT_ROOT'|" \
        /var/www/html/config.php
    docker exec "$CONTAINER" sed -i \
        "s|\$CFG->wwwroot\s*=\s*'[^']*'|\$CFG->wwwroot = 'http://localhost:$PORT'|" \
        /var/www/html/config.php
    docker exec "$CONTAINER" sed -i \
        "s|\$CFG->dataroot\s*=\s*'[^']*'|\$CFG->dataroot = '/var/www/moodledata'|" \
        /var/www/html/config.php
}

# ============================================================
# Hilfsfunktion: PHP-Extensions installieren
# ============================================================
install_php_ext() {
    local CONTAINER="$1"
    info "  → PHP-Extensions installieren in $CONTAINER..."
    docker exec "$CONTAINER" apt-get update -qq
    docker exec "$CONTAINER" apt-get install -y -qq \
        libzip-dev libpng-dev libicu-dev libxml2-dev libonig-dev 2>/dev/null
    docker exec "$CONTAINER" \
        docker-php-ext-install mysqli zip gd intl xml soap 2>/dev/null
    docker restart "$CONTAINER"
    sleep 20
}

# ============================================================
# Hilfsfunktion: Warte bis Container healthy
# ============================================================
wait_healthy() {
    local CONTAINER="$1"
    info "  → Warte bis $CONTAINER healthy..."
    for i in $(seq 1 60); do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "none")
        [[ "$STATUS" == "healthy" ]] && { ok "  $CONTAINER ist healthy"; return; }
        sleep 5
    done
    fail "$CONTAINER wurde nicht healthy"
}

# ============================================================
# SCHRITT 1: Ordner + Files
# ============================================================
info "Schritt 1/8: Ordner und Files vorbereiten..."

[[ -d "$REPO" ]] || fail "Repo nicht gefunden: $REPO\nBitte zuerst: git clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git $REPO"

mkdir -p "$BACKUPS" "$SRC" "$BASE/transit" "$BASE/prod" "$BASE/scripts" "$BASE/docs"

cp "$REPO/transit/docker-compose.3.10.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.3.11.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.4.1.yml"  "$BASE/transit/"
cp "$REPO/prod/docker-compose.yml"          "$BASE/prod/"

chown -R "$REAL_USER:$REAL_USER" "$BASE"

# .env anlegen
cat > "$TRANSIT_ENV" << EOF
MYSQL_ROOT_PASSWORD=$TRANSIT_ROOT
MYSQL_DATABASE=$TRANSIT_DB
MYSQL_USER=$TRANSIT_USER
MYSQL_PASSWORD=$TRANSIT_PW
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

ok "Ordner und Files bereit"

# ============================================================
# SCHRITT 2: Backup vom Altsystem
# ============================================================
info "Schritt 2/8: Backup vom Altsystem..."

[[ -f /var/www/html/config.php ]] || fail "Altsystem nicht gefunden — /var/www/html/config.php fehlt"
[[ -f /etc/mysql/debian.cnf ]]    || fail "/etc/mysql/debian.cnf fehlt"

# Prüfen ob Backup schon existiert
EXISTING_DB=$(ls -t "$BACKUPS"/moodle_db_*.sql.gz 2>/dev/null | head -1 || true)
EXISTING_MD=$(ls -t "$BACKUPS"/moodledata_*.tar.gz 2>/dev/null | head -1 || true)

if [[ -f "$EXISTING_DB" && -f "$EXISTING_MD" ]]; then
    info "  Backup bereits vorhanden — überspringe"
    DB_DUMP="$EXISTING_DB"
    MOODLE_TAR="$EXISTING_MD"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DB_DUMP="$BACKUPS/moodle_db_${TIMESTAMP}.sql.gz"
    MOODLE_TAR="$BACKUPS/moodledata_${TIMESTAMP}.tar.gz"

    mysqldump \
        --defaults-file=/etc/mysql/debian.cnf \
        --single-transaction \
        --routines --triggers --events \
        --databases moodle \
        | gzip > "$DB_DUMP"

    tar -czf "$MOODLE_TAR" -C /var/www moodledata
    chown "$REAL_USER:$REAL_USER" "$DB_DUMP" "$MOODLE_TAR"
fi

ok "Backup: $(basename $DB_DUMP)"

# ============================================================
# SCHRITT 3: Moodle Source vorbereiten
# ============================================================
info "Schritt 3/8: Moodle-Source vorbereiten..."

cd "$SRC"

# 3.10 aus Altsystem
if [[ ! -d "moodle-3.10" ]]; then
    info "  → Moodle 3.10 aus Altsystem kopieren..."
    mkdir -p moodle-3.10
    cp -r /var/www/html/. moodle-3.10/
    chown -R "$REAL_USER:$REAL_USER" moodle-3.10/
fi

# 3.11 Tarball
if [[ ! -f "moodle-3.11.18.tgz" ]]; then
    wget -q --show-progress -O moodle-3.11.18.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v3.11.18.tar.gz"
fi

# 4.1 Tarball
if [[ ! -f "moodle-4.1.17.tgz" ]]; then
    wget -q --show-progress -O moodle-4.1.17.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v4.1.17.tar.gz"
fi

# 3.11 entpacken
if [[ ! -d "moodle-3.11.18" ]]; then
    tar -xzf moodle-3.11.18.tgz -C .
    # GitHub entpackt als moodle-MOODLE_311... oder moodle-3.11.18
    UNPACKED=$(ls -d moodle-MOODLE_311* 2>/dev/null | head -1 || ls -d moodle-3.11.18 2>/dev/null || true)
    [[ -n "$UNPACKED" && "$UNPACKED" != "moodle-3.11.18" ]] && mv "$UNPACKED" moodle-3.11.18
fi

# 4.1 entpacken
if [[ ! -d "moodle-4.1.17" ]]; then
    tar -xzf moodle-4.1.17.tgz -C .
    UNPACKED=$(ls -d moodle-MOODLE_401* 2>/dev/null | head -1 || ls -d moodle-4.1.17 2>/dev/null || true)
    [[ -n "$UNPACKED" && "$UNPACKED" != "moodle-4.1.17" ]] && mv "$UNPACKED" moodle-4.1.17
fi

# Symlinks
ln -sfn moodle-3.11.18 moodle-3.11
ln -sfn moodle-4.1.17  moodle-4.1

# config.php für 3.11 und 4.1 vorbereiten
cp moodle-3.10/config.php moodle-3.11.18/config.php
cp moodle-3.10/config.php moodle-4.1.17/config.php

ok "Sources bereit"

# ============================================================
# SCHRITT 4: Upgrade 3.10 → 3.11
# ============================================================
info "Schritt 4/8: Upgrade 3.10 → 3.11..."
cd "$BASE/transit"

docker compose -p transit310 -f docker-compose.3.10.yml up -d
wait_healthy transit310-moodle_db

do_restore "$DB_DUMP" "$MOODLE_TAR" \
    "transit310-moodle_db" \
    "transit310-moodle_app" \
    "transit310_moodledata"

fix_config transit310-moodle_app 8090 "$SRC/moodle-3.10/config.php"
install_php_ext transit310-moodle_app

# Jetzt auf 3.11 wechseln
docker compose -p transit310 -f docker-compose.3.10.yml down

docker compose -p transit311 -f docker-compose.3.11.yml up -d
wait_healthy transit311-moodle_db

do_restore "$DB_DUMP" "$MOODLE_TAR" \
    "transit311-moodle_db" \
    "transit311-moodle_app" \
    "transit311_moodledata"

fix_config transit311-moodle_app 8091 "$SRC/moodle-3.11.18/config.php"
install_php_ext transit311-moodle_app

docker exec transit311-moodle_app \
    php /var/www/html/admin/cli/upgrade.php --non-interactive

ok "3.11 Upgrade abgeschlossen"

# ============================================================
# SCHRITT 5: DB aus 3.11 sichern
# ============================================================
info "Schritt 5/8: DB-Snapshot nach 3.11..."

docker exec \
    -e MYSQL_PWD="$TRANSIT_ROOT" \
    transit311-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_3.11_ready.sql.gz"

ok "Snapshot: moodle_3.11_ready.sql.gz"

# ============================================================
# SCHRITT 6: Upgrade 3.11 → 4.1
# ============================================================
info "Schritt 6/8: Upgrade 3.11 → 4.1..."
cd "$BASE/transit"

docker compose -p transit311 -f docker-compose.3.11.yml down
docker compose -p transit41  -f docker-compose.4.1.yml  up -d
wait_healthy transit41-moodle_db

do_restore "$BACKUPS/moodle_3.11_ready.sql.gz" "$MOODLE_TAR" \
    "transit41-moodle_db" \
    "transit41-moodle_app" \
    "transit41_moodledata"

fix_config transit41-moodle_app 8092 "$SRC/moodle-4.1.17/config.php"
install_php_ext transit41-moodle_app

# max_input_vars für 4.1
docker exec transit41-moodle_app sh -c \
    'echo "max_input_vars = 5000" > /usr/local/etc/php/conf.d/moodle.ini'
docker restart transit41-moodle_app
sleep 20

docker exec transit41-moodle_app \
    php /var/www/html/admin/cli/upgrade.php --non-interactive

ok "4.1 Upgrade abgeschlossen"

# ============================================================
# SCHRITT 7: DB aus 4.1 sichern
# ============================================================
info "Schritt 7/8: DB-Snapshot nach 4.1..."

docker exec \
    -e MYSQL_PWD="$TRANSIT_ROOT" \
    transit41-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_4.1_ready.sql.gz"

ok "Snapshot: moodle_4.1_ready.sql.gz"

# ============================================================
# SCHRITT 8: Prod-Stack (4.5 LTS)
# ============================================================
info "Schritt 8/8: Prod-Stack mit Moodle 4.5 LTS..."

docker pull bitnamilegacy/moodle:4.5

docker compose -p transit41 -f "$BASE/transit/docker-compose.4.1.yml" down
cd "$BASE/prod"
docker compose -p prod up -d

info "  → Warte bis Bitnami fertig initialisiert (~10 Min)..."
for i in $(seq 1 200); do
    docker logs prod-moodle_app 2>&1 | grep -q "Starting Apache" && break
    sleep 5
done
sleep 10

# DB mit 4.1-Daten überschreiben
docker exec \
    -e MYSQL_PWD=prodroot_changeme \
    prod-moodle_db mysql -u root \
    -e "DROP DATABASE IF EXISTS moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

zcat "$BACKUPS/moodle_4.1_ready.sql.gz" \
    | docker exec -i \
        -e MYSQL_PWD=prodroot_changeme \
        prod-moodle_db mysql -u root moodle

# Ownership für Bitnami (1001:1)
docker run --rm \
    -v prod_moodledata:/restore \
    alpine:latest \
    chown -R 1001:1 /restore

# Collation fixen
docker exec prod-moodle_app sed -i \
    "s|utf8mb4_0900_ai_ci|utf8mb4_unicode_ci|g" /bitnami/moodle/config.php

# Upgrade auf 4.5
docker exec prod-moodle_app \
    php /opt/bitnami/moodle/admin/cli/upgrade.php --non-interactive

ok "Prod-Stack fertig"

# ============================================================
# Verifikation
# ============================================================
sleep 10
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80 || echo "000")
echo ""
echo "============================================"
echo "  Migration abgeschlossen!"
echo "============================================"
echo ""
if [[ "$HTTP" == "200" || "$HTTP" == "303" ]]; then
    ok "Moodle läuft auf http://localhost:80 (HTTP $HTTP)"
else
    info "HTTP $HTTP — Moodle braucht evtl. noch etwas Zeit"
fi
echo ""
echo "  Login:  admin / Admin1234!"
echo ""
echo "  Passwort zurücksetzen falls nötig:"
echo "  docker exec -it prod-moodle_app \\"
echo "    php /opt/bitnami/moodle/admin/cli/reset_password.php"
echo ""
