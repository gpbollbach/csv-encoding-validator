FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

WORKDIR /app
RUN mkdir -p /app/data/input /app/data/output /app/data/invalid
COPY src/Test-AndFixCsvEncoding.ps1 /app/src/Test-AndFixCsvEncoding.ps1

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/src/Test-AndFixCsvEncoding.ps1"]
