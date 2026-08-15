# CSV Encoding Validator & Converter (Docker & PowerShell 7)

[![PowerShell 7](https://img.shields.io/badge/PowerShell-7+-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Docker](https://img.shields.io/badge/Docker-Desktop%20ready-2496ED?logo=docker&logoColor=white)](https://www.docker.com/products/docker-desktop/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Automatisierbares Tool, das CSV-Dateien aus einem Eingangsverzeichnis analysiert,
deren Zeichenkodierung prüft und sicherstellt, dass sie in sauberem **UTF-8
(ohne BOM)** vorliegen.

**Hintergrund:** Excel speichert CSV-Dateien beim Öffnen/Speichern oft unbemerkt
als **Windows-1252 (ANSI)** oder **ISO-8859-1**. Beim automatisierten Import in
Folgesysteme führt das zu Zeichenabbruchfehlern bzw. korrupten deutschen
Umlauten (ä, ö, ü, Ä, Ö, Ü, ß). Das Tool erkennt solche Dateien und konvertiert
sie verlustfrei nach UTF-8.

<img src="img/screenshot.png" alt="Screenshot: Container-Lauf mit Schritt-für-Schritt-Logging (BOM-Entfernung, Windows-1252-Konvertierung, Quarantäne der korrupten Datei)" width="900">

*Beispiel-Lauf: `docker run` verarbeitet vier CSV-Dateien – eine Windows-1252-Datei
wird konvertiert, eine defekte Datei nach `/invalid` quarantänisiert, die
UTF-8-Datei bleibt unverändert und die BOM wird entfernt. Exit-Code 1, da eine
Datei irreparabel war.*

## Funktionsweise

Pro Datei werden diese Schritte sequenziell durchgeführt:

| Schritt | Beschreibung |
|---|---|
| 1. BOM-Analyse | UTF-8-BOM (`EF BB BF`) wird erkannt und entfernt (Ziel: UTF-8 ohne BOM). |
| 2. Heuristische UTF-8-Validierung | Byteweise Prüfung auf valide UTF-8-Multibyte-Sequenzen (strikt, inkl. Overlong-/Surrogate-Ablehnung). |
| 3. Reparatur | Invalides UTF-8 (meist Windows-1252) wird mit Codepage 1252 gelesen und als UTF-8 ohne BOM neu geschrieben. |
| 4. Integritätsprüfung (Sanity Check) | Prüfung auf `U+FFFD`-Ersetzungszeichen, NUL-Bytes und Double-Encoding/Mojibake (z. B. `Ã¤` statt `ä`). |
| 5. Logging & Exit-Codes | Detailliertes Konsolen-Logging; Exit-Code 0 oder 1. |

**Exit-Codes**

| Code | Bedeutung |
|---|---|
| `0` | Alle Dateien valide bzw. erfolgreich konvertiert (oder keine Dateien vorhanden). |
| `1` | Unlösbare Fehler gefunden (defekte Dateien in `/invalid`, I/O-Fehler, fehlendes Eingabeverzeichnis). |

**Dateiverteilung**

- `/app/data/input` → zu prüfende CSV-Dateien
- `/app/data/output` → valide/konvertierte UTF-8-Dateien (ohne BOM)
- `/app/data/invalid` → irreparable/defekte Dateien (Quarantäne)

Defekte Dateien werden **immer** nach `/invalid` verschoben (Quarantäne).
Valide/konvertierte Dateien werden standardmäßig **kopiert** (Eingabe bleibt
unverändert, Lauf ist idempotent); mit `-Move` werden verarbeitete Dateien aus
dem Eingabeverzeichnis entfernt (verschoben bzw. nach erfolgreicher
Konvertierung gelöscht).

## Projektstruktur

```text
.
├── Dockerfile
├── docker-compose.yml
├── README.md
├── .dockerignore
├── data/                      # Volume-Quellen für docker compose
│   ├── input/
│   ├── output/
│   └── invalid/
├── src/
│   └── Test-AndFixCsvEncoding.ps1
├── img/
│   └── screenshot.png            # Beispiel-Lauf (Screenshot oben)
├── tests/
│   ├── run-tests.ps1
│   └── testdata/
│       ├── utf8_valid.csv         (Soll-Pass)
│       ├── utf8_with_bom.csv      (Soll-Fix)
│       ├── ansi_windows1252.csv   (Soll-Fix)
│       └── corrupted_encoding.csv (Soll-Fail)
└── tools/
    └── regen-testdata.py          # regeneriert die binären Fixtures
```

## Schnellstart

### 1. Image bauen

```bash
docker build -t csv-encoding-validator:latest .
```

### 2. Dateien ablegen

CSV-Dateien nach `data/input/` kopieren (oder ein anderes Verzeichnis mounten).

### 3. Verarbeiten (docker compose)

```bash
# Exit-Code wird sauber durchgereicht (0 = ok, 1 = Fehler):
docker compose run --rm csv-encoding-validator
echo "Exit-Code: $?"

# Alternativ als Einmal-Job:
docker compose up --build
```

### 4. Verarbeiten (docker run mit eigenen Verzeichnissen)

```bash
docker run --rm \
  -v "$PWD/data/input:/app/data/input" \
  -v "$PWD/data/output:/app/data/output" \
  -v "$PWD/data/invalid:/app/data/invalid" \
  csv-encoding-validator:latest
echo "Exit-Code: $?"
```

Parameter können direkt angehängt werden (werden an das Skript durchgereicht):

Der Container verarbeitet alle Dateien mit der Endung `.csv`, schreibt erfolgreiche Ergebnisse nach `data/output` und verschiebt irreparable Dateien nach `data/invalid`. Erfolgreiche Eingabedateien bleiben als Original im Eingangsverzeichnis erhalten.

## Produktiver Betrieb unter Windows ohne Docker

Das Skript kann unter Windows direkt mit PowerShell 7 ausgeführt werden. Windows PowerShell 5.1 ist nicht das Zielsystem; verwende die aktuelle plattformübergreifende PowerShell-7-Version (`pwsh.exe`). Für den produktiven Betrieb sollte das Skript aus einem festen, schreibgeschützten Deployment-Verzeichnis laufen, während die Datenverzeichnisse getrennt und zugriffsbeschränkt sind.

### 1. PowerShell 7 installieren

PowerShell 7 kann mit dem offiziellen Installer oder mit `winget` installiert werden:

```powershell
winget install --id Microsoft.PowerShell --source winget
pwsh --version
```

Installationspfad der üblichen 64-Bit-Installation:

```text
C:\Program Files\PowerShell\7\pwsh.exe
```

### 2. Anwendung und Datenverzeichnisse anlegen

Beispiel für eine produktive Ablage:

```powershell
New-Item -ItemType Directory -Force -Path `
  C:\CsvEncodingValidator\app, `
  C:\CsvEncodingValidator\data\input, `
  C:\CsvEncodingValidator\data\output, `
  C:\CsvEncodingValidator\data\invalid, `
  C:\CsvEncodingValidator\logs

Copy-Item .\src\Test-AndFixCsvEncoding.ps1 C:\CsvEncodingValidator\app\
```

Lege die zu verarbeitenden CSV-Dateien ausschließlich in `C:\CsvEncodingValidator\data\input` ab. Erfolgreiche Ergebnisse erscheinen in `data\output`; nicht sicher reparierbare Dateien werden nach `data\invalid` verschoben.

### 3. Manueller produktiver Lauf

PowerShell 7 verwendet unter Windows normale Windows-Pfade für die Parameter:

```powershell
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$script = 'C:\CsvEncodingValidator\app\Test-AndFixCsvEncoding.ps1'

& $pwsh -NoLogo -NoProfile -File $script `
  -InputDirectory 'C:\CsvEncodingValidator\data\input' `
  -OutputDirectory 'C:\CsvEncodingValidator\data\output' `
  -InvalidDirectory 'C:\CsvEncodingValidator\data\invalid'

$exitCode = $LASTEXITCODE
Write-Host "CSV validator exit code: $exitCode"
exit $exitCode
```

Exit-Code `0` bedeutet, dass alle Dateien erfolgreich verarbeitet wurden. Bei Exit-Code `1` muss `data\invalid` geprüft werden.

### 4. Automatisierung mit der Windows-Aufgabenplanung

Für einen wiederkehrenden Batch-Lauf kann die Aufgabe beispielsweise alle fünf Minuten unter einem dedizierten Dienstkonto ausgeführt werden. Erstelle zuerst eine Wrapper-Datei `C:\CsvEncodingValidator\run-validator.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$logDirectory = 'C:\CsvEncodingValidator\logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDirectory "validator-$timestamp.log"
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$script = 'C:\CsvEncodingValidator\app\Test-AndFixCsvEncoding.ps1'

& $pwsh -NoLogo -NoProfile -File $script `
  -InputDirectory 'C:\CsvEncodingValidator\data\input' `
  -OutputDirectory 'C:\CsvEncodingValidator\data\output' `
  -InvalidDirectory 'C:\CsvEncodingValidator\data\invalid' *>&1 |
  Tee-Object -FilePath $logFile

exit $LASTEXITCODE
```

Aufgabe mit PowerShell registrieren:

```powershell
$action = New-ScheduledTaskAction `
  -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
  -Argument '-NoLogo -NoProfile -NonInteractive -File "C:\CsvEncodingValidator\run-validator.ps1"'
$trigger = New-ScheduledTaskTrigger -Once (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew

Register-ScheduledTask `
  -TaskName 'CSV Encoding Validator' `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -User 'CONTOSO\svc-csv-validator' `
  -RunLevel Highest
```

Passe Dienstkonto, Trigger-Intervall und Pfade an die Umgebung an. Das Dienstkonto benötigt Leserechte für `app` und Änderungsrechte für `data` sowie `logs`; interaktive Benutzer sollten keinen Schreibzugriff auf das Skriptverzeichnis erhalten.

### 5. Produktive Betriebsregeln

- Eingabedateien erst nach vollständig abgeschlossenem Kopiervorgang in `data\input` ablegen.
- `data\output`, `data\invalid` und `logs` regelmäßig sichern und bereinigen.
- Exit-Code `1` über die Aufgabenplanung oder das Monitoring alarmieren.
- Bei parallelen Lieferantenprozessen getrennte Input-/Output-Verzeichnisse oder ein abgestimmtes Locking verwenden.
- Das Skript und PowerShell 7 kontrolliert aktualisieren und danach den Testlauf ausführen.
- Nach einer Aktualisierung zuerst mit einer Kopie der produktiven Daten testen; der Validator überschreibt vorhandene Ausgabedateien nicht.

## Verzeichnisse

```text
data/input    zu prüfende CSV-Dateien
data/output   valide und konvertierte UTF-8-Dateien ohne BOM
data/invalid  nicht sicher reparierbare CSV-Dateien
docs/         Projektdokumentation und Screenshot
src/          PowerShell-Produktionsskript
tests/        reproduzierbare Tests
```

## Logging und Exit-Codes

Das Skript protokolliert Start, Erkennung, Konvertierung, Sanity Check, Erfolg und Fehler auf Standard-Out. Der Container endet nach der Verarbeitung:

| Code | Bedeutung |
| ---: | --- |
| `0` | Alle CSV-Dateien sind valide oder wurden erfolgreich konvertiert. |
| `1` | Mindestens eine Datei konnte nicht sicher verarbeitet werden und liegt in `data/invalid`. |

## Lokale Tests

Die Testfälle werden bytegenau zur Laufzeit erzeugt; ein externes Testframework ist nicht erforderlich:

```bash
docker run --rm -v "$PWD/in:/app/data/input" -v "$PWD/out:/app/data/output" -v "$PWD/bad:/app/data/invalid" \
  csv-encoding-validator:latest -Move
```

## Skript-Parameter

```powershell
pwsh -File src/Test-AndFixCsvEncoding.ps1 [-InputDir <Pfad>] [-OutputDir <Pfad>] [-InvalidDir <Pfad>] [-Move]
```

| Parameter | Default | Beschreibung |
|---|---|---|
| `-InputDir` | `/app/data/input` | Verzeichnis mit den zu prüfenden CSV-Dateien. |
| `-OutputDir` | `/app/data/output` | Ziel für valide/konvertierte UTF-8-Dateien. |
| `-InvalidDir` | `/app/data/invalid` | Quarantäne für irreparable Dateien. |
| `-Move` | aus | Verarbeitete Dateien aus dem Eingabeverzeichnis entfernen (valide: verschieben, konvertiert: Original nach dem Schreiben löschen). |

Es werden nur Dateien mit der Endung `.csv` (case-insensitiv, nicht rekursiv)
verarbeitet. Fehlende Ausgabe-/Invalid-Verzeichnisse werden automatisch angelegt.

## Tests

Die Test-Suite führt das Skript in vier Phasen gegen die Fixtures aus
`tests/testdata/` aus (Exit-Codes, Byte-Identität, BOM-Entfernung,
1252→UTF-8-Konvertierung, Quarantäne der korrupten Datei, leere Datei,
Move-Modus):

```bash
# Lokal (PowerShell 7 erforderlich):
pwsh -NoProfile -File tests/run-tests.ps1

# Im Container (tests/ wird per Volume gemountet):
docker run --rm --entrypoint pwsh -v "$(pwd):/app" -w /app \
    csv-encoding-validator:latest -NoProfile -File /app/tests/run-tests.ps1
```

Die binären Fixtures können jederzeit neu erzeugt werden:

```bash
python3 tools/regen-testdata.py
```

## Heuristik & Grenzen (wichtig)

- **Windows-1252 vs. ISO-8859-1:** Für deutsche Umlaute sind beide Codepages
  identisch; das Tool dekodiert mit Windows-1252 (Codepage 1252). Dateien, die
  in ISO-8859-1 gespeicherte Steuerzeichen (0x80–0x9F) enthalten, werden wie
  1252 interpretiert – im CSV-Kontext praktisch irrelevant.
- **Echtes UTF-8 kann keine 1252-Kodierung enthalten und umgekehrt:** Bytes wie
  `0xE4` (ä) sind als UTF-8 niemals gültig, daher ist die Unterscheidung für
  Umlaute eindeutig.
- **Mojibake-Detektion ist heuristisch:** Das Muster `Ã/Â` + Latin-1-Zeichen
  kann in exotischen, aber legitimen Texten theoretisch falsch-positiv sein.
  Dateien mit `U+FFFD` oder NUL-Bytes (UTF-16 ohne BOM) gelten grundsätzlich
  als irreparabel → `/invalid`.
- **UTF-16/UTF-32 (mit BOM)** werden nicht unterstützt und landen in `/invalid`.
- Dateien werden vollständig in den Speicher gelesen – für sehr große Dateien
  entsprechend RAM einplanen.

## Beispiel-Log

```
[2026-08-15 11:40:00.000][INFO] === CSV Encoding Validator & Converter ===
[2026-08-15 11:40:00.000][INFO] Eingabeverzeichnis : /app/data/input
...
[2026-08-15 11:40:00.001][INFO] --- [ansi_windows1252.csv] ---
[2026-08-15 11:40:00.001][WARN] Kein valides UTF-8 – Windows-1252/ISO-8859-1 vermutet, Reparatur wird versucht.
[2026-08-15 11:40:00.003][ OK ] -> Windows-1252 -> UTF-8 konvertiert; als UTF-8 ohne BOM geschrieben: /app/data/output/ansi_windows1252.csv
[2026-08-15 11:40:00.003][INFO] === Zusammenfassung ===
...
[2026-08-15 11:40:00.004][ OK ] Exit-Code 0 – alle Dateien valide bzw. erfolgreich konvertiert.
```

## Lizenz

MIT — siehe [LICENSE](LICENSE).
