#!/usr/bin/env bash
set -euo pipefail

BACKEND="/opt/bbfs-shinobi/backend"
WEB="/var/www/jhunaey.my.id"
STAMP="$(date +%Y%m%d_%H%M%S)"
TOKEN=""

log(){ echo; echo "=== $* ==="; }

log "BACKUP"
cp "$BACKEND/server.js" "$BACKEND/server.js.before_gate_v2_final_$STAMP.bak"
[ -f "$WEB/bbfs-home-final.js" ] && cp "$WEB/bbfs-home-final.js" "$WEB/bbfs-home-final.before_gate_v2_final_$STAMP.bak" || true
[ -f "$WEB/bbfs-next-draw.html" ] && cp "$WEB/bbfs-next-draw.html" "$WEB/bbfs-next-draw.before_gate_v2_final_$STAMP.bak" || true

log "PATCH BACKEND GATE V2 FINAL"
python3 <<'PY'
from pathlib import Path

p = Path('/opt/bbfs-shinobi/backend/server.js')
s = p.read_text()
orig = s

s = s.replace(
"  if (draws.length < 20) errors.push('BBFS_INCOMPLETE: data kurang dari 20 result valid.');",
"  if (draws.length < 20) warnings.push('DATA_WARNING: data kurang dari 20 result valid.');"
)

s = s.replace(
"      errors.push('BBFS_BLOCKED_BY_PREDICTION_GATE: holdout 2D/3D terlalu rendah.');",
"      warnings.push('PREDICTION_GATE_WARNING: holdout 2D/3D rendah, tampilkan sebagai WASPADA.');"
)

s = s.replace(
"rule: 'Candidate BBFS boleh tampil hanya jika can_show_prediction = true.'",
"rule: 'BBFS tampil jika tidak ada error fatal; warning hanya mengubah status AMAN/WASPADA.'"
)

s = s.replace(
"display_gate: 'Frontend hanya boleh menampilkan kandidat jika can_show_prediction = true.'",
"display_gate: 'Frontend menampilkan BBFS jika tidak ada error fatal; warning hanya memberi status AMAN/WASPADA.'"
)

# Hapus blok Gate V2 duplikat yang mungkin tersisa dari patch sebelumnya.
def remove_block(text, marker):
    while True:
        start = text.find(marker)
        if start == -1:
            return text
        end = text.find('\n\n  return {', start)
        if end == -1:
            return text
        text = text[:start] + text[end+2:]

s = remove_block(s, '  // Gate V2:')
s = remove_block(s, '  // BBFS Gate V2:')
s = remove_block(s, '  // Gate V2 Final:')

needle = "  confidence = Number(Math.max(0, Math.min(99, confidence)).toFixed(2));\n"
block = """  confidence = Number(Math.max(0, Math.min(99, confidence)).toFixed(2));

  // Gate V2 Final:
  // HOLD hanya untuk error fatal.
  // Warning tidak mengunci BBFS.
  // AMAN jika confidence >= 45, selain itu WASPADA.
  if (canShow) {
    if (confidence >= 45) {
      predictionStatus = 'BBFS_READY';
      userStatus = 'AMAN';
    } else {
      predictionStatus = 'BBFS_READY_WITH_WARNING';
      userStatus = 'WASPADA';
    }
  }
"""
if needle not in s:
    raise SystemExit('Pattern confidence final tidak ketemu. Patch dibatalkan.')
s = s.replace(needle, block, 1)

p.write_text(s)
print('OK backend gate v2 final')
PY

log "PATCH FRONTEND RINGAN"
python3 <<'PY'
from pathlib import Path

home = Path('/var/www/jhunaey.my.id/bbfs-home-final.js')
if home.exists():
    s = home.read_text()
    s = s.replace('class="bbfs-home-status hold"', 'class="bbfs-home-status HOLD"')
    home.write_text(s)
    print('OK bbfs-home-final.js')

nextp = Path('/var/www/jhunaey.my.id/bbfs-next-draw.html')
if nextp.exists():
    s = nextp.read_text()
    s = s.replace("const bbfs=x.can_show_prediction?x.bbfs_digits:'HOLD';", "const bbfs=x.bbfs_digits||x.payload?.bbfs?.audit_digits||x.payload?.bbfs?.digits||'HOLD';")
    s = s.replace("document.getElementById('bbfs').innerHTML='';", "document.getElementById('bbfs').innerHTML=digitsHtml(bbfs.audit_digits||data.audit_digits||data.payload?.bbfs?.audit_digits||data.bbfs_digits||'');")
    home_rank2 = "document.getElementById('rank2d').innerHTML='<tr><td colspan=\"3\">Ranking ditahan.</td></tr>';"
    new_rank2 = "document.getElementById('rank2d').innerHTML=(rank2||[]).slice(0,10).map(x=>'<tr><td>'+x.rank+'</td><td>'+x.number+'</td><td>'+x.score+'</td></tr>').join('')||'<tr><td colspan=\"3\">Ranking belum tersedia.</td></tr>';"
    s = s.replace(home_rank2, new_rank2)
    home_rank3 = "document.getElementById('rank3d').innerHTML='<tr><td colspan=\"3\">Ranking ditahan.</td></tr>';"
    new_rank3 = "document.getElementById('rank3d').innerHTML=(rank3||[]).slice(0,10).map(x=>'<tr><td>'+x.rank+'</td><td>'+x.number+'</td><td>'+x.score+'</td></tr>').join('')||'<tr><td colspan=\"3\">Ranking belum tersedia.</td></tr>';"
    s = s.replace(home_rank3, new_rank3)
    nextp.write_text(s)
    print('OK bbfs-next-draw.html')
PY

log "VALIDASI NODE"
cd "$BACKEND"
node --check server.js

log "RESTART BACKEND"
systemctl restart bbfs-backend
sleep 2
systemctl status bbfs-backend --no-pager -l | head -25 || true

log "GENERATE ULANG BBFS"
TOKEN="$(grep -E '^ADMIN_API_TOKEN=' "$BACKEND/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
[ -z "$TOKEN" ] && TOKEN="bbfs_shinobi_admin_token_sementara"

curl -s -X POST "http://127.0.0.1:3001/api/bbfs/final/generate-all" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"limit":60}' | python3 -m json.tool | head -80 || true

log "CEK DISTRIBUSI STATUS"
sudo -u postgres psql -d bbfs_production -c "
SELECT user_status, prediction_status, can_show_prediction, COUNT(*) AS jumlah,
ROUND(AVG(confidence)::numeric, 2) AS avg_confidence,
MIN(confidence) AS min_confidence,
MAX(confidence) AS max_confidence
FROM bbfs_final_next_draw_predictions
GROUP BY user_status, prediction_status, can_show_prediction
ORDER BY user_status, prediction_status, can_show_prediction;
"

log "PUSH GITHUB"
bbfs-push-github || true

log "SELESAI"
echo "Buka: https://jhunaey.my.id/?v=gatev2final"
echo "Buka: https://jhunaey.my.id/bbfs-next-draw.html?v=gatev2final"
