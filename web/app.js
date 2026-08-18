/**
 * CSV Encoding Validator — UI-Logik (offline im Browser).
 * Lädt CSV-Dateien, analysiert ihr Encoding mit web/validator.js und
 * zeigt pro Datei entweder "OK" oder eine detaillierte Fehleranalyse.
 * Konvertierte (Fixed-)Dateien können als UTF-8 ohne BOM heruntergeladen werden.
 */
(function () {
  'use strict';

  var V = globalThis.CsvValidator;
  if (!V) throw new Error('validator.js wurde nicht geladen.');

  var dropzone = document.getElementById('dropzone');
  var fileInput = document.getElementById('fileInput');
  var resultsPanel = document.getElementById('results');
  var resultsList = document.getElementById('resultsList');
  var summaryEl = document.getElementById('summary');

  // ---------- Drag & Drop + Dateiauswahl ----------

  dropzone.addEventListener('click', function () { fileInput.click(); });
  dropzone.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); }
  });
  fileInput.addEventListener('change', function () {
    handleFiles(this.files);
    this.value = '';
  });

  ['dragenter', 'dragover'].forEach(function (ev) {
    dropzone.addEventListener(ev, function (e) {
      e.preventDefault();
      dropzone.classList.add('dragover');
    });
  });
  ['dragleave', 'drop'].forEach(function (ev) {
    dropzone.addEventListener(ev, function (e) {
      e.preventDefault();
      dropzone.classList.remove('dragover');
    });
  });
  dropzone.addEventListener('drop', function (e) {
    handleFiles(e.dataTransfer.files);
  });

  // ---------- Verarbeitung ----------

  function handleFiles(fileList) {
    var files = Array.prototype.slice.call(fileList);
    if (files.length === 0) return;

    resultsList.innerHTML = '';
    resultsPanel.hidden = false;

    files.forEach(function (file) {
      var card = document.createElement('div');
      card.className = 'result';
      card.innerHTML =
        '<div class="result-head">' +
          '<span class="file-name"></span>' +
          '<span class="status-pill"></span>' +
        '</div>' +
        '<p class="file-size"></p>' +
        '<div class="result-message"></div>' +
        '<div class="findings"><div class="findings-title"></div><div class="findings-tags"></div></div>' +
        '<button class="download-btn" style="display:none">⇩ UTF-8 (ohne BOM) herunterladen</button>';
      resultsList.appendChild(card);

      card.querySelector('.file-name').textContent = file.name;
      card.querySelector('.file-size').textContent = formatBytes(file.size);

      readFileAsBytes(file).then(function (bytes) {
        renderResult(card, file.name, bytes);
      }).catch(function (err) {
        renderError(card, file.name, err);
      }).finally(function () {
        updateSummary();
      });
    });
  }

  function readFileAsBytes(file) {
    return file.arrayBuffer().then(function (buf) {
      return new Uint8Array(buf);
    });
  }

  function renderResult(card, name, bytes) {
    var result = V.analyzeBytes(bytes);
    var pill = card.querySelector('.status-pill');
    var messageEl = card.querySelector('.result-message');
    var findingsEl = card.querySelector('.findings');
    var findingsTitle = findingsEl.querySelector('.findings-title');
    var findingsTags = findingsEl.querySelector('.findings-tags');
    var dl = card.querySelector('.download-btn');

    if (result.status === 'ok') {
      card.classList.add('ok');
      card.className += ' ok';
      pill.textContent = 'OK';
      pill.className = 'status-pill ok';
      messageEl.textContent = result.message;
      findingsEl.style.display = 'none';
      return;
    }

    if (result.status === 'fixed') {
      card.className += ' reason-' + result.reason;
      pill.textContent = 'Konvertiert';
      pill.className = 'status-pill warn';
      messageEl.textContent = result.message;
      findingsEl.style.display = 'none';
      dl.style.display = '';
      dl.onclick = function () {
        downloadUtf8NoBom(name, result.utf8Bytes);
      };
      return;
    }

    // invalid
    card.className += ' reason-' + (result.reason || 'invalid');
    pill.textContent = 'Fehler';
    pill.className = 'status-pill err';
    messageEl.textContent = result.message;
    dl.style.display = 'none';

    if (result.findings && result.findings.length) {
      findingsTitle.textContent = 'Analyse der Fundstellen:';
      findingsTags.innerHTML = '';
      result.findings.forEach(function (f) {
        var tag = document.createElement('span');
        tag.className = 'finding-tag';
        tag.textContent = f.context;
        tag.title = 'Position (Zeichen-Index): ' + f.index;
        findingsTags.appendChild(tag);
      });
      findingsEl.style.display = '';
    } else {
      findingsEl.style.display = 'none';
    }
  }

  function renderError(card, name, err) {
    card.className += ' reason-invalid';
    card.querySelector('.status-pill').textContent = 'Fehler';
    card.querySelector('.status-pill').className = 'status-pill err';
    card.querySelector('.result-message').textContent = 'Datei konnte nicht gelesen werden: ' + (err && err.message ? err.message : err);
    card.querySelector('.findings').style.display = 'none';
  }

  function updateSummary() {
    var cards = document.querySelectorAll('.result');
    var ok = 0, fixed = 0, bad = 0;
    cards.forEach(function (c) {
      var pill = c.querySelector('.status-pill').textContent;
      if (pill === 'OK') ok++;
      else if (pill === 'Konvertiert') fixed++;
      else bad++;
    });
    summaryEl.hidden = false;
    summaryEl.innerHTML =
      '<span class="badge ok">OK: ' + ok + '</span>' +
      '<span class="badge warn">Konvertiert: ' + fixed + '</span>' +
      '<span class="badge err">Fehler: ' + bad + '</span>';
  }

  function downloadUtf8NoBom(name, bytes) {
    var blob = new Blob([bytes], { type: 'text/csv;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    var base = name.replace(/\.csv$/i, '');
    a.href = url;
    a.download = base + '.utf8.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  function formatBytes(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1048576).toFixed(1) + ' MB';
  }
})();
