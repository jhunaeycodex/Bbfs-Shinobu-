#!/usr/bin/env bash
set -euo pipefail
OUT=/var/www/jhunaey.my.id/history-count.html
TMP=/tmp/history-count-body.tsv
sudo -u postgres psql -d bbfs_production -F $'\t' -A -q -c "SELECT m.code, COALESCE(m.name,m.code), COUNT(r.id)::int, COALESCE(MIN(r.draw_date)::text,''), COALESCE(MAX(r.draw_date)::text,'') FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name ORDER BY COUNT(r.id) ASC,m.code ASC;" > "$TMP"
python3 - <<'PY'
from pathlib import Path
rows=[]
for line in Path('/tmp/history-count-body.tsv').read_text().splitlines():
    parts=line.split('\t')
    if len(parts)>=5: rows.append(parts[:5])
total=sum(int(r[2]) for r in rows)
trs=''.join(f'<tr><td>{i}</td><td>{r[0]}</td><td>{r[1]}</td><td>{r[2]}</td><td>{r[3]}</td><td>{r[4]}</td></tr>' for i,r in enumerate(rows,1))
html=f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Total History Per Pasaran</title><style>body{{font-family:Arial;background:#081421;color:#e5e7eb;padding:18px}}table{{width:100%;border-collapse:collapse}}td,th{{border-bottom:1px solid #334155;padding:8px;text-align:left}}.box{{background:#102033;border:1px solid #26384f;border-radius:14px;padding:14px}}</style></head><body><h1>Jumlah Total History Per Pasaran</h1><div class="box">Pasaran: {len(rows)} | Total result: {total}</div><br><div class="box"><table><thead><tr><th>#</th><th>Pasaran</th><th>Nama</th><th>Total History</th><th>Awal</th><th>Akhir</th></tr></thead><tbody>{trs}</tbody></table></div></body></html>'''
Path('/var/www/jhunaey.my.id/history-count.html').write_text(html)
PY
systemctl reload nginx
echo "OK buka: https://jhunaey.my.id/history-count.html?v=1"
