#!/bin/bash
#
# setup.sh — All-in-One Moodle Migration Script
# Führt die komplette Migration von 3.10 → 3.11 → 4.1 → 4.5 LTS durch
#
# Voraussetzung:
#   - Altsystem läuft (Apache + MySQL + Moodle 3.10)
#   - Docker + Docker Compose v2 installiert
#   - Internet verfügbar (NAT in VMware)
#
# Nutzung:
#   bash setup.sh
#

set -euo pipefail

# ========== Farben ==========
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FEHLER]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ========== Konfiguration ==========
BASE="$HOME/moodle-migration"
REPO="$HOME/moodle-migration-repo"
BACKUPS="$BASE/backups"
MOODLE_SRC="$BASE/transit/moodle-src"

TRANSIT_ROOT_PW="transitroot123"
TRANSIT_DB="moodle"
TRANSIT_USER="moodle"
TRANSIT_PW="transitpass123"

echo ""
echo "========================================"
echo "  Moodle Migration — All-in-One Setup"
echo "  3.10 → 3.11 → 4.1 → 4.5 LTS"
echo "========================================"
echo ""

# ========== Schritt 1: Ordner anlegen ==========
info "Schritt 1/9: Ordner anlegen..."
mkdir -p "$BACKUPS"
mkdir -p "$MOODLE_SRC"
mkdir -p "$BASE/prod"
mkdir -p "$BASE/scripts"
mkdir -p "$BASE/docs/screenshots"
ok "Ordner angelegt"

# ========== Schritt 2: Files aus Repo kopieren ==========
info "Schritt 2/9: Files aus Repo kopieren..."
[[ -d "$REPO" ]] || fail "Repo nicht gefunden unter $REPO — bitte zuerst klonen"

cp "$REPO/transit/docker-compose.3.10.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.3.11.yml" "$BASE/transit/"
cp "$REPO/transit/docker-compose.4.1.yml"  "$BASE/transit/"
cp "$REPO/prod/docker-compose.yml"          "$BASE/prod/"
cp "$REPO/scripts/backup.sh"               "$BASE/scripts/"
cp "$REPO/scripts/restore.sh"              "$BASE/scripts/"
cp "$REPO/scripts/upgrade-step.sh"         "$BASE/scripts/"
chmod +x "$BASE/scripts/"*.sh
ok "Files kopiert"

# ========== Schritt 3: .env Dateien anlegen ==========
info "Schritt 3/9: .env Dateien anlegen..."
cat > "$BASE/transit/.env" << EOF
MYSQL_ROOT_PASSWORD=$TRANSIT_ROOT_PW
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
ok ".env Dateien angelegt"

# ========== Schritt 4: Backup vom Altsystem ==========
info "Schritt 4/9: Backup vom Altsystem erstellen..."
[[ -f /var/www/html/config.php ]] || fail "Altsystem nicht gefunden — /var/www/html/config.php existiert nicht"
sudo bash "$BASE/scripts/backup.sh"

# Neueste Backup-Dateien finden
DB_DUMP=$(ls -t "$BACKUPS"/moodle_db_*.sql.gz 2>/dev/null | head -1)
MOODLE_TAR=$(ls -t "$BACKUPS"/moodledata_*.tar.gz 2>/dev/null | head -1)
[[ -f "$DB_DUMP" ]]    || fail "DB-Dump nicht gefunden"
[[ -f "$MOODLE_TAR" ]] || fail "moodledata-Archiv nicht gefunden"
ok "Backup erstellt: $(basename $DB_DUMP)"

# ========== Schritt 5: Moodle-Tarballs ==========
info "Schritt 5/9: Moodle-Source-Tarballs herunterladen..."
cd "$MOODLE_SRC"

if [[ ! -f "moodle-3.11.18.tgz" ]]; then
    wget -q --show-progress -O moodle-3.11.18.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v3.11.18.tar.gz"
fi

if [[ ! -f "moodle-4.1.17.tgz" ]]; then
    wget -q --show-progress -O moodle-4.1.17.tgz \
        "https://github.com/moodle/moodle/archive/refs/tags/v4.1.17.tar.gz"
fi

# Moodle 3.10 Source aus Altsystem kopieren
if [[ ! -d "moodle-3.10" ]]; then
    info "Moodle 3.10 Source kopieren..."
    sudo cp -r /var/www/html/. "$MOODLE_SRC/moodle-3.10/"
    sudo chown -R "$USER:$USER" "$MOODLE_SRC/moodle-3.10/"
fi
ok "Tarballs bereit"

# ========== Schritt 6: Transit 3.10 → 3.11 ==========
info "Schritt 6/9: Upgrade 3.10 → 3.11..."
cd "$BASE/transit"

# Source vorbereiten
if [[ ! -d "$MOODLE_SRC/moodle-3.11.18" ]]; then
    tar -xzf "$MOODLE_SRC/moodle-3.11.18.tgz" -C "$MOODLE_SRC/"
    # GitHub entpackt als moodle-3.11.18 oder moodle-MOODLE_311...
    UNPACKED=$(ls -d "$MOODLE_SRC"/moodle-MOODLE_311* 2>/dev/null | head -1)
    [[ -n "$UNPACKED" ]] && mv "$UNPACKED" "$MOODLE_SRC/moodle-3.11.18"
fi
ln -sfn moodle-3.11.18 "$MOODLE_SRC/moodle-3.11"
cp "$MOODLE_SRC/moodle-3.10/config.php" "$MOODLE_SRC/moodle-3.11.18/config.php"
sed -i "s|:8090|:8091|g" "$MOODLE_SRC/moodle-3.11.18/config.php"

# Stack starten
docker compose -p transit310 -f docker-compose.3.10.yml up -d
info "Warte bis DB healthy..."
sleep 30

# Daten einspielen
bash "$BASE/scripts/restore.sh" "$DB_DUMP" "$MOODLE_TAR" transit310

# config.php in Container
docker cp "$MOODLE_SRC/moodle-3.10/config.php" transit310-moodle_app:/var/www/html/config.php
docker exec transit310-moodle_app sed -i "s/\$CFG->dbhost.*=.*'localhost'/\$CFG->dbhost = 'moodle_db'/" /var/www/html/config.php
docker exec transit310-moodle_app sed -i "s/\$CFG->dbuser.*=.*'debian-sys-maint'/\$CFG->dbuser = 'root'/" /var/www/html/config.php
docker exec transit310-moodle_app sed -i "s|\$CFG->dbpass.*=.*'.*'|\$CFG->dbpass = '$TRANSIT_ROOT_PW'|" /var/www/html/config.php
docker exec transit310-moodle_app sed -i "s|\$CFG->wwwroot.*=.*'http://localhost'|\$CFG->wwwroot = 'http://localhost:8090'|" /var/www/html/config.php

# Extensions installieren
docker exec transit310-moodle_app apt-get update -qq
docker exec transit310-moodle_app apt-get install -y -qq libzip-dev libpng-dev libicu-dev libxml2-dev libonig-dev
docker exec transit310-moodle_app docker-php-ext-install mysqli zip gd intl xml soap
docker restart transit310-moodle_app
sleep 15

# Stack wechseln auf 3.11
docker compose -p transit310 -f docker-compose.3.10.yml down
docker compose -p transit311 -f docker-compose.3.11.yml up -d
sleep 30

bash "$BASE/scripts/restore.sh" "$DB_DUMP" "$MOODLE_TAR" transit311
docker cp "$MOODLE_SRC/moodle-3.11.18/config.php" transit311-moodle_app:/var/www/html/config.php
docker exec transit311-moodle_app sed -i "s/\$CFG->dbhost.*=.*'localhost'/\$CFG->dbhost = 'moodle_db'/" /var/www/html/config.php
docker exec transit311-moodle_app sed -i "s/\$CFG->dbuser.*=.*'debian-sys-maint'/\$CFG->dbuser = 'root'/" /var/www/html/config.php
docker exec transit311-moodle_app sed -i "s|\$CFG->dbpass.*=.*'.*'|\$CFG->dbpass = '$TRANSIT_ROOT_PW'|" /var/www/html/config.php

docker exec transit311-moodle_app apt-get update -qq
docker exec transit311-moodle_app apt-get install -y -qq libzip-dev libpng-dev libicu-dev libxml2-dev
docker exec transit311-moodle_app docker-php-ext-install mysqli zip gd intl xml soap
docker restart transit311-moodle_app
sleep 15

docker exec transit311-moodle_app php /var/www/html/admin/cli/upgrade.php --non-interactive
ok "3.11 Upgrade fertig"

# ========== Schritt 7: Transit 3.11 → 4.1 ==========
info "Schritt 7/9: Upgrade 3.11 → 4.1..."
cd "$BASE/transit"

if [[ ! -d "$MOODLE_SRC/moodle-4.1.17" ]]; then
    tar -xzf "$MOODLE_SRC/moodle-4.1.17.tgz" -C "$MOODLE_SRC/"
    UNPACKED=$(ls -d "$MOODLE_SRC"/moodle-MOODLE_401* 2>/dev/null | head -1)
    [[ -n "$UNPACKED" ]] && mv "$UNPACKED" "$MOODLE_SRC/moodle-4.1.17"
fi
ln -sfn moodle-4.1.17 "$MOODLE_SRC/moodle-4.1"
cp "$MOODLE_SRC/moodle-3.11.18/config.php" "$MOODLE_SRC/moodle-4.1.17/config.php"
sed -i "s|:8091|:8092|g" "$MOODLE_SRC/moodle-4.1.17/config.php"

# DB aus 3.11 sichern
docker exec -e MYSQL_PWD=$TRANSIT_ROOT_PW transit311-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_3.11_ready.sql.gz"

docker compose -p transit311 -f docker-compose.3.11.yml down
docker compose -p transit41  -f docker-compose.4.1.yml  up -d
sleep 30

bash "$BASE/scripts/restore.sh" "$BACKUPS/moodle_3.11_ready.sql.gz" "$MOODLE_TAR" transit41
docker cp "$MOODLE_SRC/moodle-4.1.17/config.php" transit41-moodle_app:/var/www/html/config.php
docker exec transit41-moodle_app sed -i "s/\$CFG->dbhost.*=.*'localhost'/\$CFG->dbhost = 'moodle_db'/" /var/www/html/config.php
docker exec transit41-moodle_app sed -i "s/\$CFG->dbuser.*=.*'debian-sys-maint'/\$CFG->dbuser = 'root'/" /var/www/html/config.php
docker exec transit41-moodle_app sed -i "s|\$CFG->dbpass.*=.*'.*'|\$CFG->dbpass = '$TRANSIT_ROOT_PW'|" /var/www/html/config.php

docker exec transit41-moodle_app apt-get update -qq
docker exec transit41-moodle_app apt-get install -y -qq libzip-dev libpng-dev libicu-dev libxml2-dev
docker exec transit41-moodle_app docker-php-ext-install mysqli zip gd intl xml soap
docker exec transit41-moodle_app sh -c 'echo "max_input_vars = 5000" > /usr/local/etc/php/conf.d/moodle.ini'
docker restart transit41-moodle_app
sleep 15

docker exec transit41-moodle_app php /var/www/html/admin/cli/upgrade.php --non-interactive
ok "4.1 Upgrade fertig"

# ========== Schritt 8: Prod-Stack (4.5 LTS) ==========
info "Schritt 8/9: Prod-Stack mit Moodle 4.5 LTS starten..."

# DB aus 4.1 exportieren
docker exec -e MYSQL_PWD=$TRANSIT_ROOT_PW transit41-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > "$BACKUPS/moodle_4.1_ready.sql.gz"

# Image holen
docker pull bitnamilegacy/moodle:4.5

docker compose -p transit41 -f "$BASE/transit/docker-compose.4.1.yml" down
cd "$BASE/prod" && docker compose -p prod up -d

info "Warte bis Bitnami fertig initialisiert (~5-10 Min)..."
for i in $(seq 1 200); do
    docker logs prod-moodle_app 2>&1 | grep -q "Starting Apache" && break
    sleep 5
done

# DB droppen und 4.1-Dump einspielen
docker exec -e MYSQL_PWD=$TRANSIT_ROOT_PW prod-moodle_db mysql -u root \
    -e "DROP DATABASE moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

zcat "$BACKUPS/moodle_4.1_ready.sql.gz" \
    | docker exec -i -e MYSQL_PWD=$TRANSIT_ROOT_PW prod-moodle_db mysql -u root moodle

# Ownership + Collation
docker run --rm -v prod_moodledata:/restore alpine chown -R 1001:1 /restore
docker exec prod-moodle_app sed -i \
    "s|utf8mb4_0900_ai_ci|utf8mb4_unicode_ci|g" /bitnami/moodle/config.php

# Upgrade auf 4.5
docker exec prod-moodle_app php /opt/bitnami/moodle/admin/cli/upgrade.php --non-interactive
ok "Prod-Stack fertig"

# ========== Schritt 9: Verifikation ==========
info "Schritt 9/9: Verifikation..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80)
if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "303" ]]; then
    ok "Moodle läuft auf http://localhost:80 (HTTP $HTTP_STATUS)"
else
    fail "Moodle nicht erreichbar — HTTP $HTTP_STATUS"
fi

echo ""
echo "========================================"
echo "  Migration abgeschlossen!"
echo "========================================"
echo ""
echo "  Moodle:  http://localhost:80"
echo "  Login:   admin / Admin1234!"
echo ""
echo "  Passwort zurücksetzen falls nötig:"
echo "  docker exec -it prod-moodle_app \\"
echo "    php /opt/bitnami/moodle/admin/cli/reset_password.php"
echo ""
