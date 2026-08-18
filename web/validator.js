/**
 * CSV Encoding Validator & Converter — Browser-Kernlogik (offline).
 *
 * Direkte Übertragung der Erkennungslogik aus src/Test-AndFixCsvEncoding.ps1:
 *   1. BOM-Analyse  (UTF-8-BOM entfernen; UTF-16/32-BOM -> nicht unterstützt)
 *   2. Strikte byteweise UTF-8-Validierung (Overlong/Surrogate-Schutz)
 *   3. Repair: invalides UTF-8 als Windows-1252 lesen
 *   4. Sanity-Check: U+FFFD, NUL-Bytes, Double-Encoding/Mojibake
 *
 * Läuft im Browser (globale Funktion `CsvValidator`) und in Node
 * (CommonJS-Export), damit die Logik gegen die binären Fixtures getestet
 * werden kann: `node web/validator.test.js`
 */
(function (global) {
  'use strict';

  var UTF8_BOM = [0xef, 0xbb, 0xbf];
  var MOJIBAKE_RE = /[\u00C2\u00C3][\u0080-\u00BF]/g;

  var cp1252Decoder = null;
  var utf8Decoder = null;

  function decodeCp1252(bytes) {
    if (!cp1252Decoder) cp1252Decoder = new TextDecoder('windows-1252');
    return cp1252Decoder.decode(bytes);
  }

  function decodeUtf8(bytes) {
    if (!utf8Decoder) utf8Decoder = new TextDecoder('utf-8', { fatal: false });
    return utf8Decoder.decode(bytes);
  }

  function startsWith(bytes, seq) {
    if (bytes.length < seq.length) return false;
    for (var i = 0; i < seq.length; i++) {
      if (bytes[i] !== seq[i]) return false;
    }
    return true;
  }

  /**
   * Strikte byteweise UTF-8-Validierung (wie Test-StrictUtf8Bytes).
   * Lehnt Overlong-Encodings (0xC0/0xC1), Surrogate (U+D800–U+DFFF) und
   * Werte > U+10FFFF (0xF5–0xFF) ab.
   */
  function isValidUtf8(bytes) {
    var len = bytes.length;
    var i = 0;
    while (i < len) {
      var b = bytes[i];

      if (b < 0x80) { i++; continue; }                       // ASCII

      if (b >= 0xc2 && b <= 0xdf) {                          // 2 Byte
        if (i + 1 >= len) return false;
        var c1 = bytes[i + 1];
        if (c1 < 0x80 || c1 > 0xbf) return false;
        i += 2; continue;
      }

      if (b === 0xe0) {                                      // 3 Byte, Overlong-Schutz
        if (i + 2 >= len) return false;
        var e1 = bytes[i + 1], e2 = bytes[i + 2];
        if (e1 < 0xa0 || e1 > 0xbf || e2 < 0x80 || e2 > 0xbf) return false;
        i += 3; continue;
      }

      if (b >= 0xe1 && b <= 0xec) {                          // 3 Byte
        if (i + 2 >= len) return false;
        var f1 = bytes[i + 1], f2 = bytes[i + 2];
        if (f1 < 0x80 || f1 > 0xbf || f2 < 0x80 || f2 > 0xbf) return false;
        i += 3; continue;
      }

      if (b === 0xed) {                                      // 3 Byte, Surrogate-Schutz
        if (i + 2 >= len) return false;
        var d1 = bytes[i + 1], d2 = bytes[i + 2];
        if (d1 < 0x80 || d1 > 0x9f || d2 < 0x80 || d2 > 0xbf) return false;
        i += 3; continue;
      }

      if (b >= 0xee && b <= 0xef) {                          // 3 Byte
        if (i + 2 >= len) return false;
        var g1 = bytes[i + 1], g2 = bytes[i + 2];
        if (g1 < 0x80 || g1 > 0xbf || g2 < 0x80 || g2 > 0xbf) return false;
        i += 3; continue;
      }

      if (b === 0xf0) {                                      // 4 Byte, Overlong-Schutz
        if (i + 3 >= len) return false;
        var h1 = bytes[i + 1], h2 = bytes[i + 2], h3 = bytes[i + 3];
        if (h1 < 0x90 || h1 > 0xbf || h2 < 0x80 || h2 > 0xbf || h3 < 0x80 || h3 > 0xbf) return false;
        i += 4; continue;
      }

      if (b >= 0xf1 && b <= 0xf3) {                          // 4 Byte
        if (i + 3 >= len) return false;
        var j1 = bytes[i + 1], j2 = bytes[i + 2], j3 = bytes[i + 3];
        if (j1 < 0x80 || j1 > 0xbf || j2 < 0x80 || j2 > 0xbf || j3 < 0x80 || j3 > 0xbf) return false;
        i += 4; continue;
      }

      if (b === 0xf4) {                                      // 4 Byte, Grenze U+10FFFF
        if (i + 3 >= len) return false;
        var k1 = bytes[i + 1], k2 = bytes[i + 2], k3 = bytes[i + 3];
        if (k1 < 0x80 || k1 > 0x8f || k2 < 0x80 || k2 > 0xbf || k3 < 0x80 || k3 > 0xbf) return false;
        i += 4; continue;
      }

      return false;                                          // 0x80–0xC1, 0xF5–0xFF
    }
    return true;
  }

  /** Sammelt die ersten `limit` Treffer einer globalen Regex mit Kontext. */
  function collectFindings(regex, text, limit) {
    var out = [];
    var m;
    while (out.length < limit && (m = regex.exec(text)) !== null) {
      var start = Math.max(0, m.index - 14);
      var end = Math.min(text.length, m.index + m[0].length + 14);
      out.push({ index: m.index, context: text.slice(start, end) });
      if (m.index === regex.lastIndex) regex.lastIndex++;
    }
    return out;
  }

  /** Sammelt die ersten `limit` Vorkommen eines Zeichens mit Kontext. */
  function collectCharFindings(ch, text, limit) {
    var out = [];
    var from = 0;
    while (out.length < limit) {
      var idx = text.indexOf(ch, from);
      if (idx === -1) break;
      var start = Math.max(0, idx - 14);
      var end = Math.min(text.length, idx + 1 + 14);
      out.push({ index: idx, context: text.slice(start, end) });
      from = idx + 1;
    }
    return out;
  }

  /**
   * Integritätsprüfung des dekodierten Texts (wie Test-SaneText).
   * Liefert null, wenn in Ordnung, sonst { reason, message, findings }.
   */
  function sanityCheck(text) {
    var replacement = '\uFFFD';
    if (text.indexOf(replacement) !== -1) {
      return {
        reason: 'replacement',
        message: 'Ersetzungszeichen U+FFFD gefunden — Inhalt ist beschädigt.',
        findings: collectCharFindings(replacement, text, 5)
      };
    }
    if (text.indexOf('\u0000') !== -1) {
      return {
        reason: 'nul',
        message: 'NUL-Bytes (0x00) gefunden — vermutlich UTF-16 ohne BOM.',
        findings: collectCharFindings('\u0000', text, 5)
      };
    }
    MOJIBAKE_RE.lastIndex = 0;
    var m = MOJIBAKE_RE.exec(text);
    if (m) {
      return {
        reason: 'mojibake',
        message: "Double-Encoding/Mojibake erkannt (z. B. 'Ã¤' statt 'ä') — die Datei wurde vermutlich schon einmal falsch umkodiert.",
        findings: collectFindings(MOJIBAKE_RE, text, 5)
      };
    }
    return null;
  }

  function bomReason(bytes) {
    if (startsWith(bytes, UTF8_BOM)) return 'utf8';
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return 'utf16le';
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) return 'utf16be';
    if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0xfe && bytes[3] === 0xff) return 'utf32';
    return null;
  }

  /**
   * Analysiert ein Byte-Array (Uint8Array) und liefert:
   *   { status: 'ok' }                          valide UTF-8 ohne BOM
   *   { status: 'fixed', reason, message, utf8Bytes }  BOM entfernt oder 1252 -> UTF-8
   *   { status: 'invalid', reason, message, findings } irreparabel + Fehleranalyse
   */
  function analyzeBytes(bytes) {
    if (!(bytes instanceof Uint8Array)) {
      bytes = new Uint8Array(bytes);
    }

    if (bytes.length === 0) {
      return { status: 'ok', reason: 'empty', message: 'Leere Datei — formal valides UTF-8.' };
    }

    var bom = bomReason(bytes);

    if (bom === 'utf8') {
      var payload = bytes.subarray(3);
      if (isValidUtf8(payload)) {
        return {
          status: 'fixed',
          reason: 'bom',
          message: 'UTF-8-BOM (EF BB BF) erkannt und entfernt — Ziel: UTF-8 ohne BOM.',
          utf8Bytes: payload
        };
      }
      // BOM + invalider Rest (selten): Repair des Rests als Windows-1252
      var textBom = decodeCp1252(payload);
      var issueBom = sanityCheck(textBom);
      if (issueBom) {
        return { status: 'invalid', reason: issueBom.reason, message: issueBom.message, findings: issueBom.findings };
      }
      return {
        status: 'fixed',
        reason: 'bom-repair',
        message: 'BOM entfernt; der Rest war kein valides UTF-8 und wurde als Windows-1252 gelesen und nach UTF-8 konvertiert.',
        utf8Bytes: new TextEncoder().encode(textBom)
      };
    }

    if (bom === 'utf16le' || bom === 'utf16be' || bom === 'utf32') {
      return {
        status: 'invalid',
        reason: 'unsupported-encoding',
        message: 'UTF-16/UTF-32-BOM erkannt — diese Encodings werden nicht unterstützt (Ziel: UTF-8 ohne BOM). Bitte die Datei als UTF-8 (ohne BOM) speichern.',
        findings: []
      };
    }

    if (isValidUtf8(bytes)) {
      var textValid = decodeUtf8(bytes);
      var issueValid = sanityCheck(textValid);
      if (issueValid) {
        return { status: 'invalid', reason: issueValid.reason, message: issueValid.message, findings: issueValid.findings };
      }
      return { status: 'ok', reason: 'utf8', message: 'Valides UTF-8 ohne BOM — keine Änderung nötig.' };
    }

    // Fall B: invalides UTF-8 (meist Windows-1252/ISO-8859-1)
    var text1252 = decodeCp1252(bytes);
    var issue1252 = sanityCheck(text1252);
    if (issue1252) {
      return { status: 'invalid', reason: issue1252.reason, message: issue1252.message, findings: issue1252.findings };
    }
    return {
      status: 'fixed',
      reason: 'converted',
      message: 'Kein valides UTF-8 — als Windows-1252 gelesen und nach UTF-8 (ohne BOM) konvertiert.',
      utf8Bytes: new TextEncoder().encode(text1252)
    };
  }

  var api = {
    analyzeBytes: analyzeBytes,
    isValidUtf8: isValidUtf8,
    sanityCheck: sanityCheck,
    bomReason: bomReason,
    MOJIBAKE_RE: /[\u00C2\u00C3][\u0080-\u00BF]/g
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else {
    global.CsvValidator = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
