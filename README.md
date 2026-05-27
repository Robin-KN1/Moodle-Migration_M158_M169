# Moodle Migration 3.10 → 4.5 LTS

Automatisierte Migrationspipeline von Moodle 3.10 auf 4.5 LTS mit Docker.
Moodle unterstützt keine direkten Sprünge zwischen Hauptversionen — Updates müssen schrittweise durchgeführt werden.

**Upgrade-Pfad:** `3.10.11` → `3.11.18` → `4.1.17` → `4.5 LTS`

**Team:** Noah Kronhardt · Robin Weder · Nico Bischof — GBS St.Gallen (M158/M169)

---

## Voraussetzungen

| Anforderung | Wert |
|---|---|
| Betriebssystem | Ubuntu 22.04+ |
| Docker Engine | 20.10+ mit Compose v2 |
| Moodle-Pfad | `/var/www/html` |
| Datenpfad | `/var/www/moodledata` |
| MySQL-Config | `/etc/mysql/debian.cnf` |
| Freier Speicher | ~10 GB |
| Netzwerk | Internetzugang für `docker pull` |

---

## Verwendung

```bash
# Repo klonen
git clone https://github.com/Robin-KN1/Moodle-Migration_M158_M169.git ~/moodle-migration-repo

# Migration starten
sudo bash ~/moodle-migration-repo/scripts/setup.sh
```

> **Hinweis:** Erster Durchlauf dauert ca. 20–40 Minuten. Das Skript ist idempotent — bereits vorhandene Backups und heruntergeladene Quellen werden beim erneuten Ausführen wiederverwendet. Nach Abschluss läuft Moodle 4.5 LTS unter http://localhost.

---

## Was setup.sh macht

| Schritt | Beschreibung |
|---|---|
| 1 | Erstellt Arbeitsverzeichnisse, schreibt `.env`-Dateien und kopiert Compose-Konfigurationen |
| 2 | Erstellt Backup der Moodle-Datenbank und `moodledata` (wird übersprungen falls bereits vorhanden) |
| 3 | Lädt Moodle 3.11.18 und 4.1.17 herunter und erstellt Versions-Symlinks |
| 4 | Startet den `transit310`-Stack, stellt Backup wieder her und installiert PHP-Erweiterungen |
| 5 | Upgrade auf 3.11: Neustart mit `transit311`, Daten wiederherstellen, `upgrade.php` ausführen |
| 6 | Erstellt Snapshot der 3.11-Datenbank |
| 7 | Upgrade auf 4.1: Neustart mit `transit41`, 3.11-Snapshot einspielen, `upgrade.php` ausführen |
| 8 | Bitnami 4.5-Produktivstack starten, migrierte DB + moodledata importieren, auf 4.5 upgraden |

Die Transit-Stacks werden nach jeder Phase mit `--volumes` entfernt, damit MySQL bei jedem erneuten Start sauber initialisiert wird.

---

## Konfiguration

Passwörter und Einstellungen befinden sich am Anfang von `setup.sh`:

| Variable | Standardwert | Beschreibung |
|---|---|---|
| `TRANSIT_ROOT` | `transitroot123` | MySQL-Root-Passwort für alle Transit-Stacks |
| `BASE` | `~/moodle-migration` | Arbeitsverzeichnis |
| `REPO` | `~/moodle-migration-repo` | Dieses Repository |

Die Zugangsdaten für den Produktivstack werden in `$BASE/prod/.env` gespeichert:

```env
MYSQL_ROOT_PASSWORD=prodroot_changeme
MYSQL_PASSWORD=prodpass_changeme
MOODLE_PASSWORD=Admin1234!
```

---

## Repository-Struktur

```
.
├── scripts/
│   └── setup.sh                  # Hauptskript für die Migration
├── transit/
│   ├── docker-compose.3.10.yml
│   ├── docker-compose.3.11.yml
│   └── docker-compose.4.1.yml
└── prod/
    └── docker-compose.yml        # Bitnami Moodle 4.5 LTS
```

Die Transit-Stacks binden die Moodle-Quellen aus `$BASE/transit/moodle-src/` ein und verwenden benannte Volumes (`transit310_*`, `transit311_*`, `transit41_*`).
Der Produktivstack verwendet `bitnamilegacy/moodle:4.5`.

---

## Fehlerbehebung

**Migration bricht mittendrin ab — kann das Skript erneut ausgeführt werden?**

Ja. Bereits vorhandene Backups und heruntergeladene Quellen werden übersprungen. Vor jeder Phase werden alle Transit-Stacks mit `down -v` bereinigt, damit keine alten Volumes Probleme verursachen.

---

**`ERROR 1045 (28000): Access denied for user 'root'`**

Entsteht durch alte MySQL-Volumes eines vorherigen fehlgeschlagenen Durchlaufs. In der aktuellen Version behoben — Transit-Stacks starten immer mit neuen Volumes.

---

**HTTP 500 nach dem Start des Produktivsystems**

Meistens falsche Berechtigungen auf `/bitnami/moodledata`. Bitnami setzt die Berechtigungen beim Start automatisch korrekt — nicht manuell mit `chown` ändern.

---

**`bitnami/moodle:4.5` nicht gefunden**

Das Image wurde verschoben. Die Compose-Datei verweist bereits auf das richtige Image:

```
bitnamilegacy/moodle:4.5
```

---

**Altsystem parallel auf Port 8080 betreiben**

Das Skript stoppt Apache, damit Port 80 frei wird. Um die alte Installation parallel weiterlaufen zu lassen:

```bash
sudo sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf
sudo systemctl start apache2
```
