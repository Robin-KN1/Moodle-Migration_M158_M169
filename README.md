Moodle Migration 3.10 → 4.5 LTS

Automatisierte Migrationspipeline von Moodle 3.10 auf 4.5 LTS mit Docker.
Moodle unterstützt keine direkten Sprünge zwischen Hauptversionen, deshalb müssen die Updates schrittweise durchgeführt werden.

Upgrade-Pfad: 3.10 → 3.11 → 4.1 → 4.5 LTS

Team: Noah Kronhardt, Robin Weder, Nico Bischof — GBS St.Gallen (M158/M169)

Voraussetzungen
Ubuntu 22.04 (oder kompatibel)
Docker Engine 20.10+ mit Compose v2 (docker compose statt docker-compose)
Laufende Moodle-3.10-Installation unter /var/www/html
Moodle-Daten unter /var/www/moodledata
MySQL-Zugriff über /etc/mysql/debian.cnf
Ca. 10 GB freier Speicherplatz
Internetzugang für docker pull
Verwendung
git clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git ~/moodle-migration-repo
sudo bash ~/moodle-migration-repo/scripts/setup.sh

Das Skript läuft vollständig automatisiert und ist idempotent. Bereits vorhandene Backups und heruntergeladene Quellen werden bei erneutem Ausführen wiederverwendet. Nach Abschluss läuft Moodle 4.5 LTS unter http://localhost.

Hinweis: Der erste Durchlauf dauert ca. 20–40 Minuten. Bitnami initialisiert zuerst intern eine neue Moodle-Instanz, bevor die migrierten Daten importiert werden.

Was setup.sh macht
Schritt	Beschreibung
1	Erstellt Arbeitsverzeichnisse, schreibt .env-Dateien und kopiert Compose-Konfigurationen
2	Erstellt ein Backup der bestehenden Moodle-Datenbank und von moodledata (wird übersprungen, falls bereits vorhanden)
3	Lädt Moodle 3.11.18 und 4.1.17 herunter und erstellt Versions-Symlinks
4	Startet den transit310-Stack, stellt das Backup wieder her und installiert PHP-Erweiterungen
5	Führt das Upgrade auf 3.11 durch: Neustart mit transit311, Wiederherstellung der Daten und Ausführen von upgrade.php
6	Erstellt einen Snapshot der 3.11-Datenbank
7	Führt das Upgrade auf 4.1 durch: Neustart mit transit41, Wiederherstellung des 3.11-Snapshots und Ausführen von upgrade.php
8	Startet den Bitnami-4.5-Produktivstack, importiert die migrierte Datenbank sowie moodledata und aktualisiert auf 4.5

Die Transit-Stacks werden nach jeder Phase mit --volumes entfernt, damit MySQL bei jedem erneuten Start sauber initialisiert wird.

Konfiguration

Passwörter und Einstellungen befinden sich am Anfang von setup.sh:

Variable	Standardwert	Beschreibung
TRANSIT_ROOT	transitroot123	MySQL-Root-Passwort für alle Transit-Stacks
BASE	~/moodle-migration	Arbeitsverzeichnis
REPO	~/moodle-migration-repo	Dieses Repository

Die Zugangsdaten für den Produktivstack werden in Schritt 1 in $BASE/prod/.env gespeichert. Falls nötig, können sie vor dem Start in setup.sh angepasst werden:

MYSQL_ROOT_PASSWORD=prodroot_changeme
MYSQL_PASSWORD=prodpass_changeme
MOODLE_PASSWORD=Admin1234!
Repository-Struktur
.
├── scripts/
│   └── setup.sh              # Hauptskript für die Migration
├── transit/
│   ├── docker-compose.3.10.yml
│   ├── docker-compose.3.11.yml
│   └── docker-compose.4.1.yml
└── prod/
    └── docker-compose.yml    # Bitnami Moodle 4.5 LTS

Die Transit-Stacks binden die Moodle-Quellen aus $BASE/transit/moodle-src/ ein und verwenden benannte Volumes (transit310_*, transit311_*, transit41_*).
Der Produktivstack verwendet bitnamilegacy/moodle:4.5.

Fehlerbehebung
Migration bricht mittendrin ab — kann das Skript erneut ausgeführt werden?

Ja. Bereits vorhandene Backups und heruntergeladene Quellen werden übersprungen. Vor jeder Phase werden alle Transit-Stacks mit down -v bereinigt, damit keine alten Volumes Probleme verursachen.

ERROR 1045 (28000): Access denied for user 'root'

Dieser Fehler entsteht meistens durch alte MySQL-Volumes eines vorherigen fehlgeschlagenen Durchlaufs.
Das Problem wurde in der aktuellen Version behoben — Transit-Stacks werden immer mit neuen Volumes gestartet.

HTTP 500 nach dem Start des Produktivsystems

Meistens liegt das an falschen Berechtigungen auf /bitnami/moodledata.
Der Bitnami-Container muss als daemon (uid=1) laufen. Nicht manuell mit chown auf uid 1001 ändern — Bitnami setzt die Berechtigungen beim Start automatisch korrekt.

bitnami/moodle:4.5 nicht gefunden

Das Image wurde nach bitnamilegacy/moodle:4.5 verschoben.
Die Compose-Datei verweist bereits auf das richtige Image.

Alte Moodle-Version weiterhin auf Port 8080 betreiben

Das Skript stoppt Apache, damit Port 80 frei wird.
Um die alte Installation parallel weiterlaufen zu lassen:

sudo sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf
sudo systemctl start apache2
