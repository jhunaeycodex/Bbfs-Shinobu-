#!/usr/bin/env bash
set -euo pipefail
WEB=/var/www/jhunaey.my.id
BE=/opt/bbfs-shinobi/backend
HTML=$WEB/db-export-import.html
SERVER=$BE/server.js
[ -f "$HTML" ] || { echo "GAGAL: $HTML tidak ada"; exit 1; }
[ -f "$SERVER" ] || { echo "GAGAL: $SERVER tidak ada"; exit 1; }
cp "$HTML" "$HTML.bak-count-$(date +%Y%m%d-%H%M%S)"
cp "$SERVER" "$SERVER.bak-count-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
server=Path('/opt/bbfs-shinobi/backend/server.js')
s=server.read_text(encoding='utf-8')
route="""
app.get('/api/admin/result-counts', requireAdminToken, async (req, res) => {
  try {
    const q = await pool.query(`
      SELECT m.code AS market_code, COALESCE(m.name, m.code) AS market_name,
             COUNT(r.id)::int AS total_history,
             MIN(r.draw_date)::text AS first_date,
             MAX(r.draw_date)::text AS last_date
      FROM markets m
      LEFT JOIN result_draws r ON r.market_id = m.id
      WHERE COALESCE(m.is_active, true) = true
      GROUP BY m.id, m.code, m.name
      ORDER BY total_history ASC, m.code ASC
    `);
    res.json({ ok: true, data: q.rows });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});
"""
if "/api/admin/result-counts" not in s:
    marker="app.listen"
    if marker in s:
        s=s.replace(marker, route+"\n"+marker, 1)
    else:
        s += "\n"+route
    server.write_text(s,encoding='utf-8')
html=Path('/var/www/jhunaey.my.id/db-export-import.html')
h=html.read_text(encoding='utf-8')
section="""
<section class="card" id="historyCountBox">
  <h2>Jumlah Total History Per Pasaran</h2>
  <button onclick="loadHistoryCounts()">MUAT JUMLAH HISTORY</button>
  <button onclick="downloadHistoryCountsCsv()">DOWNLOAD CSV COUNT</button>
  <div id="historyCountSummary" class="muted"></div>
  <div style="overflow:auto;max-height:520px;margin-top:10px">
    <table id="historyCountTable"><thead><tr><th>#</th><th>Pasaran</th><th>Nama</th><th>Total History</th><th>Awal</th><th>Akhir</th></tr></thead><tbody></tbody></table>
  </div>
</section>
"""
js="""
<script id="history-count-per-market-js">
let historyCountsCache=[];
function adminHeaders(){
  const t=(document.getElementById('adminToken')?.value||localStorage.getItem('bbfs_admin_pin')||'').trim();
  return t ? {Authorization:'Bearer '+t,'X-Admin-Pin':t} : {};
}
async function loadHistoryCounts(){
  const r=await fetch('/api/admin/result-counts',{headers:adminHeaders(),cache:'no-store'});
  const j=await r.json();
  if(!j.ok){alert(j.error||'Gagal memuat count');return;}
  historyCountsCache=j.data||[];
  const tb=document.querySelector('#historyCountTable tbody');
  tb.innerHTML=historyCountsCache.map((x,i)=>`<tr><td>${i+1}</td><td>${x.market_code}</td><td>${x.market_name}</td><td>${x.total_history}</td><td>${x.first_date||''}</td><td>${x.last_date||''}</td></tr>`).join('');
  const total=historyCountsCache.reduce((a,x)=>a+Number(x.total_history||0),0);
  document.getElementById('historyCountSummary').textContent=`Pasaran: ${historyCountsCache.length} | Total result: ${total}`;
}
function downloadHistoryCountsCsv(){
  if(!historyCountsCache.length){alert('Muat jumlah history dulu');return;}
  const rows=['market_code,market_name,total_history,first_date,last_date'];
  historyCountsCache.forEach(x=>rows.push([x.market_code,x.market_name,x.total_history,x.first_date||'',x.last_date||''].map(v=>'"'+String(v).replaceAll('"','""')+'"').join(',')));
  const a=document.createElement('a');
  a.href=URL.createObjectURL(new Blob([rows.join('\n')],{type:'text/csv'}));
  a.download='total_history_per_pasaran.csv';
  a.click();
}
</script>
"""
if 'historyCountBox' not in h:
    h=h.replace('</body>', section+js+'</body>') if '</body>' in h else h+section+js
html.write_text(h,encoding='utf-8')
PY
systemctl restart bbfs-backend
systemctl reload nginx
echo 'OK: buka https://jhunaey.my.id/db-export-import.html?v=history-count'
