#!/usr/bin/env bash
set -euo pipefail
HTML=/var/www/jhunaey.my.id/db-export-import.html
cp "$HTML" "$HTML.bak-upload-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/jhunaey.my.id/db-export-import.html')
s=p.read_text(encoding='utf-8')
if 'id="csvFile"' not in s:
    s=s.replace('<textarea id="csvInput" spellcheck="false"', '<input id="csvFile" type="file" accept=".csv,text/csv,text/plain" style="margin:0 0 10px" onchange="loadCsvFile(event)" />\n        <textarea id="csvInput" spellcheck="false"')
if 'function loadCsvFile' not in s:
    s=s.replace('function parseCsvPreview(){', """function loadCsvFile(ev){
  const f = ev.target.files && ev.target.files[0];
  if(!f) return;
  const reader = new FileReader();
  reader.onload = () => {
    $('csvInput').value = String(reader.result || '');
    parseCsvPreview();
    log('File CSV dimuat: ' + f.name);
  };
  reader.readAsText(f, 'utf-8');
}
function parseCsvPreview(){""")
p.write_text(s,encoding='utf-8')
PY
systemctl reload nginx
echo 'OK: upload CSV aktif di https://jhunaey.my.id/db-export-import.html?v=file-upload'
