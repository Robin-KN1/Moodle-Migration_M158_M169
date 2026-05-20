#!/bin/bash
#
# upgrade-step.sh — führt Moodle-Upgrade-Routine in einem laufenden Container aus.
#
# Nutzung:
#   bash upgrade-step.sh <container-name> <ziel-version>
#
# Beispiel:
#   bash upgrade-step.sh transit311-moodle_app 3.11.18
#

set -euo pipefail

# ========== Argumente ==========
if [[ $# -lt 2 ]]; then
    echo "Nutzung: $0 <container-name> <ziel-version>" >&2
    echo "Beispiel: $0 transit311-moodle_app 3.11.18" >&2
    exit 1
fi

CONTAINER="$1"
ZIEL_VERSION="$2"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/moodle-migration/docs"
LOG_FILE="${LOG_DIR}/upgrade_${ZIEL_VERSION}_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

echo "=== Moodle Upgrade-Routine: $(date) ===" | tee "$LOG_FILE"
echo "Container:     $CONTAINER"               | tee -a "$LOG_FILE"
echo "Ziel-Version:  $ZIEL_VERSION"            | tee -a "$LOG_FILE"
echo ""                                         | tee -a "$LOG_FILE"

# ========== Vorab-Check: Container läuft? ==========
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" || {
    echo "Fehler: Container $CONTAINER läuft nicht." >&2
    exit 1
}

# ========== Schritt 1: PHP-Extensions prüfen ==========
echo "[1/4] PHP-Extensions prüfen..." | tee -a "$LOG_FILE"
docker exec "$CONTAINER" php -m | tee -a "$LOG_FILE"

# ========== Schritt 2: Moodle-Version vor Upgrade ==========
echo "" | tee -a "$LOG_FILE"
echo "[2/4] Moodle-Version vor Upgrade:" | tee -a "$LOG_FILE"
docker exec "$CONTAINER" \
    grep -E "release|version|maturity" /var/www/html/version.php \
    | grep -v "//" \
    | tee -a "$LOG_FILE"

# ========== Schritt 3: Upgrade-Routine ausführen ==========
echo "" | tee -a "$LOG_FILE"
echo "[3/4] Upgrade-Routine läuft..." | tee -a "$LOG_FILE"
docker exec "$CONTAINER" \
    php /var/www/html/admin/cli/upgrade.php --non-interactive \
    | tee -a "$LOG_FILE"

# ========== Schritt 4: Moodle-Version nach Upgrade ==========
echo "" | tee -a "$LOG_FILE"
echo "[4/4] Moodle-Version nach Upgrade:" | tee -a "$LOG_FILE"
docker exec "$CONTAINER" \
    grep -E "release|version|maturity" /var/www/html/version.php \
    | grep -v "//" \
    | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "=== Upgrade abgeschlossen: $(date) ===" | tee -a "$LOG_FILE"
echo "Log gespeichert: $LOG_FILE"
echo ""
echo "Nächster Schritt:"
echo "  Browser öffnen und Login testen"
echo "  Dann Git-Tag setzen:"
echo "  git tag phase-${ZIEL_VERSION}-upgraded"
echo "  git push --tags"