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

## Interaktives Diagramm

Ein interaktives **Workflow-Diagramm** des Validators (Hauptpfad, BOM-Analyse,
UTF-8-Prüfung, Windows-1252-Reparatur, Sanity-Check und Verteilung auf
`output/`/`invalid/` inkl. Exit-Codes) liegt im Repository:

> 📊 [`docs/workflow-csv-validator.html`](docs/workflow-csv-validator.html)

Die Diagrammdatei ist ein eigenständiger, interaktiver Viewer (Theme-Umschaltung
Hell/Dunkel, Pan/Zoom, Suche, Fokus und Export). Einfach im Browser öffnen —
keine Installation nötig.

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
├── docs/
│   └── workflow-csv-validator.html   # interaktives Workflow-Diagramm
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

Parameter können direkt angehängt werden (werden an das Skript durchgereicht),
z. B. `csv-encoding-validator:latest -Move`. Der Container verarbeitet alle
Dateien mit der Endung `.csv`, schreibt erfolgreiche Ergebnisse nach
`data/output` und verschiebt irreparable Dateien nach `data/invalid`.

## Produktiver Betrieb unter Windows ohne Docker

Das Tool ist ein reines PowerShell-Skript — Docker ist nur eine Option für den
isolierten Lauf. Unter Windows kann es direkt mit PowerShell produktiv
betrieben werden (z. B. über die Windows-Aufgabenplanung), ganz ohne Container.

**Voraussetzungen**

- Windows 10/11 — enthält **Windows PowerShell 5.1** (`powershell.exe`) nativ.
- Empfohlen: **PowerShell 7** (`pwsh`) — dieselbe Laufzeitumgebung wie der
  Docker-Container und die getestete Umgebung. Installation per `winget`:

  ```powershell
  winget install --id Microsoft.PowerShell --source winget
  pwsh --version
  ```

  Üblicher Installationspfad: `C:\Program Files\PowerShell\7\pwsh.exe`.
  PowerShell 7 wird für die Produktion empfohlen; mit Windows PowerShell 5.1
  läuft das Skript grundsätzlich ebenfalls (Hinweis zur Skript-Kodierung unten).

**1. Deployment-Ordner anlegen**

Produktives Layout — Skript schreibgeschützt in `app`, Daten getrennt in `data`:

```powershell
New-Item -ItemType Directory -Force -Path `
  C:\CsvEncodingValidator\app, `
  C:\CsvEncodingValidator\data\input, `
  C:\CsvEncodingValidator\data\output, `
  C:\CsvEncodingValidator\data\invalid, `
  C:\CsvEncodingValidator\logs

Copy-Item .\src\Test-AndFixCsvEncoding.ps1 C:\CsvEncodingValidator\app\
```

CSV-Dateien ausschließlich in `data\input` ablegen; erfolgreiche Ergebnisse
erscheinen in `data\output`, irreparable Dateien landen in `data\invalid`.

**2. Manueller produktiver Lauf**

```powershell
$pwsh   = 'C:\Program Files\PowerShell\7\pwsh.exe'
$script = 'C:\CsvEncodingValidator\app\Test-AndFixCsvEncoding.ps1'

& $pwsh -NoLogo -NoProfile -File $script `
  -InputDir   'C:\CsvEncodingValidator\data\input' `
  -OutputDir  'C:\CsvEncodingValidator\data\output' `
  -InvalidDir 'C:\CsvEncodingValidator\data\invalid'

$exitCode = $LASTEXITCODE
Write-Host "CSV validator exit code: $exitCode"
exit $exitCode
```

Exit-Code `0` = alle Dateien valide/konvertiert; `1` = unlösbare Fehler →
`data\invalid` prüfen. Für Windows PowerShell 5.1 entsprechend
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File …` verwenden.

**3. Automatisierung über die Windows-Aufgabenplanung**

Wrapper `C:\CsvEncodingValidator\run-validator.ps1` (loggt jeden Lauf mit
Zeitstempel):

```powershell
$ErrorActionPreference = 'Stop'
$logDirectory = 'C:\CsvEncodingValidator\logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile   = Join-Path $logDirectory "validator-$timestamp.log"
$pwsh      = 'C:\Program Files\PowerShell\7\pwsh.exe'
$script    = 'C:\CsvEncodingValidator\app\Test-AndFixCsvEncoding.ps1'

& $pwsh -NoLogo -NoProfile -File $script `
  -InputDir   'C:\CsvEncodingValidator\data\input' `
  -OutputDir  'C:\CsvEncodingValidator\data\output' `
  -InvalidDir 'C:\CsvEncodingValidator\data\invalid' -Move *>&1 |
  Tee-Object -FilePath $logFile

exit $LASTEXITCODE
```

`-Move` entfernt verarbeitete Dateien aus dem Eingang (keine
Doppelverarbeitung). Ohne `-Move` bleibt der Lauf idempotent — Dateien bleiben
im Eingang und werden bei jedem Lauf erneut (identisch) verarbeitet.

Aufgabe registrieren (Beispiel: alle 5 Minuten unter einem Dienstkonto):

```powershell
$action = New-ScheduledTaskAction `
  -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
  -Argument '-NoLogo -NoProfile -NonInteractive -File "C:\CsvEncodingValidator\run-validator.ps1"'
$trigger  = New-ScheduledTaskTrigger -Once (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew

Register-ScheduledTask `
  -TaskName 'CSV Encoding Validator' `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -User 'CONTOSO\svc-csv-validator' `
  -RunLevel Highest
```

Dienstkonto, Intervall und Pfade an die Umgebung anpassen. Das Dienstkonto
benötigt Leserechte für `app` und Änderungsrechte für `data` sowie `logs`.
Das „Letzte Ergebnis" des Tasks ist `0` (Erfolg) oder `1` (unlösbare Fehler).
Alternativ lässt sich derselbe Wrapper über die Aufgabenplanung-GUI
(*Aufgabe erstellen* → Programm `pwsh.exe` mit obigem Argument) oder
`schtasks /Create …` anlegen.

**4. Produktive Betriebsregeln**

- Eingabedateien erst nach vollständig abgeschlossenem Kopiervorgang in
  `data\input` ablegen.
- `data\output`, `data\invalid` und `logs` regelmäßig sichern und bereinigen.
- Exit-Code `1` über die Aufgabenplanung oder das Monitoring alarmieren.
- Bei parallelen Lieferantenprozessen getrennte Input-/Output-Verzeichnisse
  oder ein abgestimmtes Locking verwenden.
- Vorhandene Ausgabedateien gleichen Namens werden überschrieben — vor
  Wiederholungsläufen `data\output`/`data\invalid` prüfen.
- Skript und PowerShell kontrolliert aktualisieren und danach einen Testlauf
  ausführen.

**Hinweis zur Skript-Kodierung**

Die `.ps1` ist als UTF-8 ohne BOM abgelegt. PowerShell 7 liest das korrekt.
Windows PowerShell 5.1 interpretiert `.ps1` ohne BOM als ANSI — dann werden
Umlaute in Log-Meldungen falsch dargestellt. Für den Betrieb mit 5.1 die Datei
einmalig als *UTF-8 mit BOM* speichern (z. B. VS Code → Speichern unter →
*Encoding: UTF-8 with BOM*). Die Encoding-Erkennung/-Konvertierung des Tools
arbeitet byte-genau und ist von der Kodierung der Skriptdatei unabhängig.

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
