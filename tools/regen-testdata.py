#!/usr/bin/env python3
"""Regeneriert die binären CSV-Test-Fixtures in tests/testdata/.

Fixtures:
  utf8_valid.csv          - valides UTF-8 ohne BOM                    (Soll-Pass)
  utf8_with_bom.csv       - UTF-8 mit BOM                             (Soll-Fix)
  ansi_windows1252.csv    - Windows-1252 (ANSI) mit deutschen Umlauten (Soll-Fix)
  corrupted_encoding.csv  - doppelt kodiertes UTF-8 (Mojibake) + U+FFFD (Soll-Fail)

Aufruf: python3 tools/regen-testdata.py  (aus dem Projektroot)
"""
import codecs
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "tests", "testdata")

# Gemeinsamer Inhalt der "guten" Fixtures (Umlaute ä ö ü Ä Ö Ü ß)
TEXT = "Name;Stadt;Notiz\nMüller;München;Grüße\nStraße;Österreich;für ÄÖÜ äöü ß\n"


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)

    # 1) Valides UTF-8 ohne BOM
    with open(os.path.join(OUT_DIR, "utf8_valid.csv"), "wb") as f:
        f.write(TEXT.encode("utf-8"))

    # 2) UTF-8 mit BOM
    with open(os.path.join(OUT_DIR, "utf8_with_bom.csv"), "wb") as f:
        f.write(codecs.BOM_UTF8 + TEXT.encode("utf-8"))

    # 3) Windows-1252 (ANSI) – gleicher Inhalt, Codepage 1252
    with open(os.path.join(OUT_DIR, "ansi_windows1252.csv"), "wb") as f:
        f.write(TEXT.encode("cp1252"))

    # 4) Korrupt: UTF-8-Inhalt, der als Windows-1252 fehlinterpretiert und
    #    erneut als UTF-8 gespeichert wurde (Double-Encoding/Mojibake),
    #    plus ein echtes U+FFFD-Ersetzungszeichen.
    #    Die Datei ist selbst *valides* UTF-8 -> besteht Byte-Check,
    #    scheitert aber am Sanity-Check.
    mojibake = TEXT.encode("utf-8").decode("cp1252")   # z.B. 'MÃ¼ller;MÃ¼nchen...'
    corrupt = mojibake + "M" + "\ufffd" + "ller;Kaputt;Ersetzungszeichen\n"
    with open(os.path.join(OUT_DIR, "corrupted_encoding.csv"), "wb") as f:
        f.write(corrupt.encode("utf-8"))

    # --- Selbstvalidierung der Fixtures ---
    errors = []
    p = os.path.join(OUT_DIR, "utf8_valid.csv")
    b = open(p, "rb").read()
    assert b.decode("utf-8") == TEXT, "utf8_valid Inhalt falsch"
    assert not b.startswith(codecs.BOM_UTF8), "utf8_valid darf keine BOM haben"

    p = os.path.join(OUT_DIR, "utf8_with_bom.csv")
    b = open(p, "rb").read()
    assert b.startswith(codecs.BOM_UTF8), "utf8_with_bom muss BOM haben"
    assert b[3:].decode("utf-8") == TEXT, "utf8_with_bom Inhalt falsch"

    p = os.path.join(OUT_DIR, "ansi_windows1252.csv")
    b = open(p, "rb").read()
    assert b.decode("cp1252") == TEXT, "ansi_windows1252 Inhalt falsch"
    try:
        b.decode("utf-8")
        errors.append("ansi_windows1252 darf KEIN valides UTF-8 sein")
    except UnicodeDecodeError:
        pass

    p = os.path.join(OUT_DIR, "corrupted_encoding.csv")
    b = open(p, "rb").read()
    s = b.decode("utf-8")          # muss valides UTF-8 sein
    assert "\ufffd" in s, "corrupted muss U+FFFD enthalten"
    assert "Ã¼" in s or "Ã" in s, "corrupted muss Mojibake enthalten"

    if errors:
        for e in errors:
            print("FEHLER:", e)
        return 1
    print("Fixtures OK ->", OUT_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
