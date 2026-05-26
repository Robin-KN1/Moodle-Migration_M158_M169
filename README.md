# Moodle Migration — M158 / M169

Schulprojekt GBS St.Gallen. Wir migrieren Moodle 3.10 auf Moodle 4.5 LTS mit Docker.

**Team:** Noah Kronhardt, Robin Weder, Nico Bischof  
**Auftraggeber:** Oliver Lux

---

## Was wir gemacht haben

Moodle kann nicht direkt von 3.10 auf 4.5 springen — es braucht Zwischenstufen:

```
3.10 → 3.11 → 4.1 → 4.5 LTS
```

Pro Stufe haben wir einen eigenen Docker-Stack verwendet:

| Stack | Port | Zweck |
|---|---|---|
| `transit310` | 8090 | Ausgangszustand (3.10) |
| `transit311` | 8091 | Upgrade auf 3.11 |
| `transit41` | 8092 | Upgrade auf 4.1 |
| `prod` | 80 | Finaler Stack (4.5 LTS) |

---

## Voraussetzungen

- Docker 20.10+ mit Compose v2
- VMware mit **NAT** (nicht Bridged — hat bei uns nicht funktioniert)
- ~5 GB freier Speicher
- Internet für `docker pull`

---

## Repo auf die VM klonen

```bash
# Repo klonen
git clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git moodle-migration-repo

# Reingehen
cd moodle-migration-repo

# Prüfen ob alles da ist
ls
```

Danach noch die Arbeitsordner anlegen die nicht im Repo sind:

```bash
mkdir -p ~/moodle-migration/backups
mkdir -p ~/moodle-migration/transit/moodle-src
mkdir -p ~/moodle-migration/prod
mkdir -p ~/moodle-migration/docs/screenshots

# Compose-Files und Scripts rüberkopieren
cp -r ~/moodle-migration-repo/transit/*.yml ~/moodle-migration/transit/
cp -r ~/moodle-migration-repo/prod/docker-compose.yml ~/moodle-migration/prod/
cp -r ~/moodle-migration-repo/scripts/* ~/moodle-migration/scripts/ 2>/dev/null || \
    mkdir -p ~/moodle-migration/scripts && cp -r ~/moodle-migration-repo/scripts/* ~/moodle-migration/scripts/
```

**.env Dateien anlegen** (kommen nicht ins Repo wegen Passwörtern):

```bash
# transit/.env
cat > ~/moodle-migration/transit/.env << 'EOF'
MYSQL_ROOT_PASSWORD=transitroot123
MYSQL_DATABASE=moodle
MYSQL_USER=moodle
MYSQL_PASSWORD=transitpass123
EOF

# prod/.env
cat > ~/moodle-migration/prod/.env << 'EOF'
MYSQL_ROOT_PASSWORD=prodroot_changeme
MYSQL_DATABASE=moodle
MYSQL_USER=moodle
MYSQL_PASSWORD=prodpass_changeme
MOODLE_USERNAME=admin
MOODLE_PASSWORD=Admin1234!
MOODLE_EMAIL=admin@moodle.local
EOF
```

**Backup-Dateien erstellen** (kommen nicht ins Repo, müssen lokal erzeugt werden):

Die Backup-Dateien (`moodle_db_*.sql.gz` und `moodledata_*.tar.gz`) sind nicht im Repo — sie werden direkt vom Altsystem erstellt. Das Altsystem muss laufen (Apache + MySQL auf Port 8080).

```bash
sudo bash ~/moodle-migration/scripts/backup.sh
```

Danach liegen die Dateien unter `~/moodle-migration/backups/`. Ohne diese Dateien kann `restore.sh` nicht ausgeführt werden.

---

**Moodle-Tarballs herunterladen** (nicht im Repo, zu gross):

```bash
cd ~/moodle-migration/transit/moodle-src

wget -O moodle-3.11.18.tgz \
    "https://github.com/moodle/moodle/archive/refs/tags/v3.11.18.tar.gz"

wget -O moodle-4.1.17.tgz \
    "https://github.com/moodle/moodle/archive/refs/tags/v4.1.17.tar.gz"
```

---

## Schnellstart (Prod-Stack starten)

```bash
cd ~/moodle-migration/prod
docker compose -p prod up -d
```

Moodle läuft dann auf **http://localhost:80**

---

## Migrationspfad

### Phase 0 — Backup einspielen (3.10)

```bash
cd ~/moodle-migration/transit
docker compose -p transit310 -f docker-compose.3.10.yml up -d

bash ~/moodle-migration/scripts/restore.sh \
    ~/moodle-migration/backups/moodle_db_20260513_141059.sql.gz \
    ~/moodle-migration/backups/moodledata_20260513_141059.tar.gz \
    transit310
```

### Phase 1 — Upgrade 3.10 → 3.11

```bash
cd ~/moodle-migration/transit

# Source vorbereiten
tar -xzf moodle-src/moodle-3.11.18.tgz -C moodle-src/
ln -sfn moodle-3.11.18 moodle-src/moodle-3.11
cp moodle-src/moodle-3.10/config.php moodle-src/moodle-3.11.18/config.php
sed -i "s|:8090|:8091|" moodle-src/moodle-3.11.18/config.php

# Stack wechseln
docker compose -p transit310 -f docker-compose.3.10.yml down
docker compose -p transit311 -f docker-compose.3.11.yml up -d

# Daten einspielen
bash ~/moodle-migration/scripts/restore.sh \
    ~/moodle-migration/backups/moodle_db_20260513_141059.sql.gz \
    ~/moodle-migration/backups/moodledata_20260513_141059.tar.gz \
    transit311

# PHP-Extensions installieren (müssen manuell rein)
docker exec transit311-moodle_app apt-get update -qq
docker exec transit311-moodle_app apt-get install -y -qq libzip-dev libpng-dev libicu-dev libxml2-dev
docker exec transit311-moodle_app docker-php-ext-install mysqli zip gd intl xml soap
docker restart transit311-moodle_app

# Upgrade ausführen
docker exec transit311-moodle_app php /var/www/html/admin/cli/upgrade.php --non-interactive

git -C ~/moodle-migration-repo tag phase-3.11-upgraded
```

### Phase 2 — Upgrade 3.11 → 4.1

```bash
cd ~/moodle-migration/transit

# Source vorbereiten
tar -xzf moodle-src/moodle-4.1.17.tgz -C moodle-src/
ln -sfn moodle-4.1.17 moodle-src/moodle-4.1
cp moodle-src/moodle-3.11.18/config.php moodle-src/moodle-4.1.17/config.php
sed -i "s|:8091|:8092|" moodle-src/moodle-4.1.17/config.php

# DB aus 3.11 sichern
docker exec -e MYSQL_PWD=transitroot123 transit311-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > ~/moodle-migration/backups/moodle_3.11_ready.sql.gz

# Stack wechseln
docker compose -p transit311 -f docker-compose.3.11.yml down
docker compose -p transit41 -f docker-compose.4.1.yml up -d

bash ~/moodle-migration/scripts/restore.sh \
    ~/moodle-migration/backups/moodle_3.11_ready.sql.gz \
    ~/moodle-migration/backups/moodledata_20260513_141059.tar.gz \
    transit41

# Extensions + PHP-Config
docker exec transit41-moodle_app apt-get update -qq
docker exec transit41-moodle_app apt-get install -y -qq libzip-dev libpng-dev libicu-dev libxml2-dev
docker exec transit41-moodle_app docker-php-ext-install mysqli zip gd intl xml soap
docker exec transit41-moodle_app sh -c 'echo "max_input_vars = 5000" > /usr/local/etc/php/conf.d/moodle.ini'
docker restart transit41-moodle_app

docker exec transit41-moodle_app php /var/www/html/admin/cli/upgrade.php --non-interactive

git -C ~/moodle-migration-repo tag phase-4.1-upgraded
```

### Phase 3 — Prod-Stack (4.5 LTS)

```bash
# DB aus 4.1 exportieren
docker exec -e MYSQL_PWD=transitroot123 transit41-moodle_db \
    mysqldump -u root --single-transaction --databases moodle \
    | gzip > ~/moodle-migration/backups/moodle_4.1_ready.sql.gz

# Image holen (bitnami war offline, daher bitnamilegacy)
docker pull bitnamilegacy/moodle:4.5

# Prod starten und warten bis fertig
docker compose -p transit41 -f ~/moodle-migration/transit/docker-compose.4.1.yml down
cd ~/moodle-migration/prod && docker compose -p prod up -d

# Warten bis Bitnami fertig installiert hat (~5-10 Min)
for i in $(seq 1 200); do
    docker logs prod-moodle_app 2>&1 | grep -q "Starting Apache" && break
    sleep 5
done

# DB droppen und neu einspielen
docker exec -e MYSQL_PWD=transitroot123 prod-moodle_db mysql -u root \
    -e "DROP DATABASE moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

zcat ~/moodle-migration/backups/moodle_4.1_ready.sql.gz \
    | docker exec -i -e MYSQL_PWD=transitroot123 prod-moodle_db mysql -u root moodle

# Ownership setzen
docker run --rm -v prod_moodledata:/restore alpine chown -R 1001:1 /restore

# Collation fixen
docker exec prod-moodle_app sed -i \
    "s|utf8mb4_0900_ai_ci|utf8mb4_unicode_ci|g" /bitnami/moodle/config.php

# Upgrade auf 4.5
docker exec prod-moodle_app php /opt/bitnami/moodle/admin/cli/upgrade.php --non-interactive

git -C ~/moodle-migration-repo tag phase-4.5-prod-ready
git -C ~/moodle-migration-repo push --tags
```

---

## Backup & Restore

```bash
# Backup
bash ~/moodle-migration/scripts/backup.sh

# Restore in einen Stack
bash ~/moodle-migration/scripts/restore.sh \
    ~/moodle-migration/backups/<db-dump>.sql.gz \
    ~/moodle-migration/backups/<moodledata>.tar.gz \
    <stack-prefix>
```

---

## Troubleshooting — was bei uns schief lief

**mysqli fehlt im Container**
```bash
docker exec <container> docker-php-ext-install mysqli
docker restart <container>
```

**Theme-Fehler (`theme/theme/version.php not found`)**
```bash
docker exec <container> rm -rf /var/www/html/theme/theme
```

**Container heissen bei uns ohne `-1`**  
Also `transit310-moodle_app` statt `transit310-moodle_app-1` — weil wir `container_name` im Compose-File gesetzt haben.

**`$HOME` bei sudo ist `/root`**  
Immer absolute Pfade verwenden: `/home/vmadmin/moodle-migration/...` statt `~/...`

**Moodle-Tarballs von download.moodle.org liefern HTML**  
Von GitHub ziehen: `https://github.com/moodle/moodle/archive/refs/tags/v3.11.18.tar.gz`

**VMware Bridged funktioniert nicht im Schulnetz**  
Auf NAT umstellen: VM Settings → Network Adapter → NAT

**`bitnami/moodle:4.5` nicht verfügbar**  
`bitnamilegacy/moodle:4.5` verwenden — gleiches Image, anderer Name.

**HTTP 500 nach Prod-Restore**  
Ownership falsch gesetzt. Fix: `docker run --rm -v prod_moodledata:/restore alpine chown -R 1001:1 /restore`

**`max_input_vars` Fehler bei 4.1-Upgrade**
```bash
docker exec <container> sh -c 'echo "max_input_vars = 5000" > /usr/local/etc/php/conf.d/moodle.ini'
docker restart <container>
```

**Collation-Fehler**  
`dbcollation` in config.php auf `utf8mb4_unicode_ci` setzen.

---

## Git-Repo

https://github.com/Robin-KN1/Moodle-Migration_M158_M169
