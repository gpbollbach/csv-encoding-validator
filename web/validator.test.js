/**
 * Node-Test für die Browser-Kernlogik (web/validator.js) gegen die binären
 * Fixtures aus tests/testdata/.
 *
 * Aufruf: node web/validator.test.js
 * Voraussetzung: Node mit full-ICU (TextDecoder 'windows-1252').
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { analyzeBytes, isValidUtf8 } = require('./validator.js');

const TESTDATA = path.join(__dirname, '..', 'tests', 'testdata');
const EXPECTED = 'Name;Stadt;Notiz\nMüller;München;Grüße\nStraße;Österreich;für ÄÖÜ äöü ß\n';

let passed = 0;
let failed = 0;

function check(name, cond) {
  if (cond) {
    passed++;
    console.log(`[PASS] ${name}`);
  } else {
    failed++;
    console.log(`[FAIL] ${name}`);
  }
}

function load(name) {
  return new Uint8Array(fs.readFileSync(path.join(TESTDATA, name)));
}

// --- Fixtures existieren ---
for (const f of ['utf8_valid.csv', 'utf8_with_bom.csv', 'ansi_windows1252.csv', 'corrupted_encoding.csv']) {
  check(`Fixture vorhanden: ${f}`, fs.existsSync(path.join(TESTDATA, f)));
}

// --- 1) Valides UTF-8 ohne BOM -> ok ---
let r = analyzeBytes(load('utf8_valid.csv'));
check('utf8_valid.csv -> status ok', r.status === 'ok');
check('utf8_valid.csv -> Grund utf8', r.reason === 'utf8');
check('utf8_valid.csv -> keine Download-Daten', r.utf8Bytes === undefined);

// --- 2) UTF-8 mit BOM -> fixed (BOM entfernt) ---
const valid = load('utf8_valid.csv');
const bom = load('utf8_with_bom.csv');
r = analyzeBytes(bom);
check('utf8_with_bom.csv -> status fixed', r.status === 'fixed');
check('utf8_with_bom.csv -> Grund bom', r.reason === 'bom');
check('utf8_with_bom.csv -> BOM entfernt (3 Bytes kürzer)', r.utf8Bytes.length === bom.length - 3);
check('utf8_with_bom.csv -> Inhalt identisch zu utf8_valid', r.utf8Bytes.length === valid.length &&
      r.utf8Bytes.every((b, i) => b === valid[i]));
check('utf8_with_bom.csv -> keine BOM mehr', r.utf8Bytes[0] !== 0xef);

// --- 3) Windows-1252 -> fixed (konvertiert, Umlaute erhalten) ---
r = analyzeBytes(load('ansi_windows1252.csv'));
check('ansi_windows1252.csv -> status fixed', r.status === 'fixed');
check('ansi_windows1252.csv -> Grund converted', r.reason === 'converted');
const decoded = new TextDecoder('utf-8').decode(r.utf8Bytes);
check('ansi_windows1252.csv -> Umlaute korrekt (ä ö ü Ä Ö Ü ß)', decoded === EXPECTED);
check('ansi_windows1252.csv -> konvertierte Bytes sind valides UTF-8', isValidUtf8(r.utf8Bytes));

// --- 4) Korrupt (Mojibake + U+FFFD, selbst valides UTF-8) -> invalid ---
r = analyzeBytes(load('corrupted_encoding.csv'));
check('corrupted_encoding.csv -> status invalid', r.status === 'invalid');
check('corrupted_encoding.csv -> Grund mojibake oder replacement',
      r.reason === 'mojibake' || r.reason === 'replacement');
check('corrupted_encoding.csv -> Fehleranalyse mit Fundstellen', Array.isArray(r.findings) && r.findings.length > 0);
check('corrupted_encoding.csv -> Fundstellen haben Kontext', r.findings.every((f) => typeof f.context === 'string' && f.context.length > 0));

// --- 5) Edge Cases ---
r = analyzeBytes(new Uint8Array(0));
check('leere Datei -> status ok', r.status === 'ok' && r.reason === 'empty');

// UTF-16 LE BOM (FF FE)
r = analyzeBytes(new Uint8Array([0xff, 0xfe, 0x4d, 0x00, 0x00, 0x00]));
check('UTF-16 LE BOM -> invalid (unsupported-encoding)', r.status === 'invalid' && r.reason === 'unsupported-encoding');

// 0xC3 allein (unvollständige UTF-8-Sequenz) -> wird als 1252 repariert
r = analyzeBytes(new Uint8Array([0x47, 0x72, 0xc3, 0x65])); // "Gr?e"
check('abgeschnittene UTF-8-Sequenz -> fixed (converted)', r.status === 'fixed' && r.reason === 'converted');

// NUL-Bytes (UTF-16 ohne BOM-Erkennung)
r = analyzeBytes(new Uint8Array([0x4d, 0x00, 0x00, 0x00, 0x00, 0x00]));
check('NUL-Bytes -> invalid (nul)', r.status === 'invalid' && r.reason === 'nul');

// 0xE4 (ä als Windows-1252, für sich allein) -> invalides UTF-8 -> konvertiert
r = analyzeBytes(new Uint8Array([0x4d, 0xfc, 0x6c, 0x6c, 0x65, 0x72])); // Müll(er) in 1252
check('Windows-1252-Umlaute (0xFC) -> fixed (converted)', r.status === 'fixed' && r.reason === 'converted');
check('Windows-1252-Umlaute -> korrektes ü', new TextDecoder('utf-8').decode(r.utf8Bytes) === 'Müller');

// --- Ergebnis ---
console.log('');
console.log(`Ergebnis: ${passed} bestanden, ${failed} fehlgeschlagen`);
if (failed > 0) {
  console.log('TEST-SUITE FEHLGESCHLAGEN');
  process.exit(1);
}
console.log('TEST-SUITE BESTANDEN');
process.exit(0);
