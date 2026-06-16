#!/usr/bin/env bash
set -euo pipefail
S=/opt/bbfs-shinobi/backend/server.js
[ -f "$S" ] || { echo "GAGAL: $S tidak ditemukan"; exit 1; }
cp "$S" "$S.bak-gate-2d3d-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/bbfs-shinobi/backend/server.js')
s=p.read_text(encoding='utf-8')
if 'CONFIDENCE_GATE_2D3D_PRIORITY_V1' in s:
    print('Sudah terpasang: CONFIDENCE_GATE_2D3D_PRIORITY_V1')
    raise SystemExit
old="""  const holdoutScore = holdout.status === 'DONE'
    ? holdout.bbfs_4d_rate * 25 + holdout.bbfs_3d_rate * 15 + holdout.bbfs_2d_rate * 10
    : 5;
  const stabilityScore = Math.max(0, Math.min(20, scoreGap * 5));"""
new="""  // CONFIDENCE_GATE_2D3D_PRIORITY_V1:
  // AMAN/WASPADA lebih mengutamakan 2D belakang dan 3D belakang.
  // 2D = Kepala-Ekor, 3D = Kop-Kepala-Ekor. 123 dari 1234 tetap MISS.
  const holdoutScore = holdout.status === 'DONE'
    ? holdout.bbfs_2d_rate * 25 + holdout.bbfs_3d_rate * 25 + holdout.bbfs_4d_rate * 10
    : 5;
  const stabilityScore = Math.max(0, Math.min(15, scoreGap * 4));"""
if old not in s:
    raise SystemExit('Pola confidence gate lama tidak ditemukan. Stop agar tidak salah patch.')
s=s.replace(old,new,1)
s=s.replace('const dataScore = Math.min(20, (draws.length / 100) * 20);','const dataScore = Math.min(10, (draws.length / 100) * 10);',1)
s=s.replace('const freshnessScore = Math.max(0, 20 - freshDays * 2);','const freshnessScore = Math.max(0, 15 - freshDays * 1.5);',1)
s=s.replace("""    if (!holdout.baseline_pass.bbfs_2d && !holdout.baseline_pass.bbfs_3d) {
      warnings.push('BASELINE_WARNING: holdout 2D/3D belum mengalahkan baseline random.');
    }""","""    if (!holdout.baseline_pass.bbfs_2d || !holdout.baseline_pass.bbfs_3d) {
      warnings.push('BASELINE_WARNING: fokus 2D/3D belakang belum kuat.');
    }""",1)
s=s.replace("""      rule: 'BBFS tampil jika tidak ada error fatal; warning hanya mengubah status AMAN/WASPADA.'""","""      rule: 'BBFS tampil jika tidak ada error fatal; AMAN/WASPADA diprioritaskan oleh 2D/3D belakang.'""",1)
p.write_text(s,encoding='utf-8')
PY
node -c "$S"
systemctl restart bbfs-backend
systemctl start bbfs-auto-statistika.service || true
echo "OK: Confidence gate 2D/3D belakang aktif"
echo "Cek hasil: sudo -u postgres psql -d bbfs_production -c \"SELECT m.code,p.bbfs_digits,p.confidence,p.prediction_status,p.user_status,p.updated_at FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id ORDER BY p.updated_at DESC LIMIT 20;\""
