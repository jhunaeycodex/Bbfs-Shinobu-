#!/usr/bin/env bash
set -euo pipefail
S=/opt/bbfs-shinobi/backend/server.js
[ -f "$S" ] || { echo "GAGAL: $S tidak ditemukan"; exit 1; }
cp "$S" "$S.bak-gate-2d3d-back-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/bbfs-shinobi/backend/server.js')
s=p.read_text(encoding='utf-8')
if 'CONFIDENCE_GATE_2D3D_BACK_V1' in s:
    print('Sudah terpasang: CONFIDENCE_GATE_2D3D_BACK_V1')
    raise SystemExit
s=s.replace("""  const holdoutScore = holdout.status === 'DONE'
    ? holdout.bbfs_4d_rate * 25 + holdout.bbfs_3d_rate * 15 + holdout.bbfs_2d_rate * 10
    : 5;
  const stabilityScore = Math.max(0, Math.min(20, scoreGap * 5));""","""  // CONFIDENCE_GATE_2D3D_BACK_V1:
  // AMAN/WASPADA mengutamakan 2D belakang (KEPALA-EKOR) dan 3D belakang (KOP-KEPALA-EKOR).
  // 4D tetap dihitung, tapi tidak dominan.
  const holdoutScore = holdout.status === 'DONE'
    ? holdout.bbfs_2d_rate * 25 + holdout.bbfs_3d_rate * 25 + holdout.bbfs_4d_rate * 10
    : 5;
  const stabilityScore = Math.max(0, Math.min(15, scoreGap * 4));""",1)
s=s.replace("""  const dataScore = Math.min(20, (draws.length / 100) * 20);
  const freshnessScore = Math.max(0, 20 - freshDays * 2);""","""  const dataScore = Math.min(10, (draws.length / 100) * 10);
  const freshnessScore = Math.max(0, 15 - freshDays * 1.5);""",1)
s=s.replace("""      confidence_calibration: {
      value: confidence,""","""      confidence_gate_mode: 'CONFIDENCE_GATE_2D3D_BACK_V1',
      confidence_priority: {
        rule: '2D belakang dan 3D belakang menjadi penentu utama AMAN/WASPADA.',
        valid_3d_example: 'Result 1234 => 3D valid hanya 234; 123/124 miss.',
        valid_2d_example: 'Result 1234 => 2D valid hanya 34; 12/23 miss.'
      },
      confidence_calibration: {
      value: confidence,""",1)
p.write_text(s,encoding='utf-8')
PY
node -c "$S"
systemctl restart bbfs-backend
systemctl start bbfs-auto-statistika.service || true
echo "OK: Confidence gate sekarang fokus 2D/3D belakang"
echo "Cek: grep -n 'CONFIDENCE_GATE_2D3D_BACK_V1' /opt/bbfs-shinobi/backend/server.js"
