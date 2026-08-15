# ===========================================================================
# CSV Encoding Validator & Converter – Docker-Image
#
# Basis: offizielles PowerShell-LTS-Image (leichtgewichtig).
# Die offiziellen PowerShell-Linux-Images sind plattformspezifisch:
#   arm64 (Apple Silicon, Default):  mcr.microsoft.com/powershell:lts-azurelinux-3.0-arm64
#   amd64 (Server/CI, schlanker):    mcr.microsoft.com/powershell:lts-alpine
# Auf amd64-Hosts entsprechend bauen:
#   docker build --build-arg BASE_IMAGE=mcr.microsoft.com/powershell:lts-alpine .
# ===========================================================================
ARG BASE_IMAGE=mcr.microsoft.com/powershell:lts-azurelinux-3.0-arm64
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="CSV Encoding Validator & Converter" \
      org.opencontainers.image.description="Prüft CSV-Dateien auf Zeichenkodierung und konvertiert sie nach UTF-8 (ohne BOM)" \
      org.opencontainers.image.version="1.0.0"

# Arbeitsverzeichnis und Skript (Skript wird nicht ins Image gemountet, sondern eingebaut)
WORKDIR /app
COPY src/Test-AndFixCsvEncoding.ps1 /app/Test-AndFixCsvEncoding.ps1

# Datenverzeichnisse – werden in der Regel per Volume gemountet
#   /app/data/input   -> zu prüfende CSV-Dateien
#   /app/data/output  -> valide/konvertierte UTF-8-Dateien
#   /app/data/invalid -> irreparable/defekte Dateien
RUN mkdir -p /app/data/input /app/data/output /app/data/invalid

# Einmal-Lauf: verarbeitet alle CSV-Dateien in /app/data/input und beendet sich.
# Exit-Codes: 0 = alle Dateien valide/erfolgreich konvertiert,
#             1 = unlösbare Fehler gefunden (defekte Dateien in /invalid).
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/Test-AndFixCsvEncoding.ps1"]
