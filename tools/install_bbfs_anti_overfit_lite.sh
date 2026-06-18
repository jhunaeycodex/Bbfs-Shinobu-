#!/usr/bin/env bash
set -euo pipefail
S=/opt/bbfs-shinobi/backend/server.js
[ -f "$S" ] || { echo "GAGAL: $S tidak ditemukan"; exit 1; }
cp "$S" "$S.bak-anti-overfit-lite-$(date +%Y%m%d-%H%M%S)"
# pastikan patch dasar ada
curl -fsSL https://raw.githubusercontent.com/jhunaeycodex/Bbfs-Shinobu-/main/tools/install_bbfs_statistika_adaptive_v2.sh | bash || true
curl -fsSL https://raw.githubusercontent.com/jhunaeycodex/Bbfs-Shinobu-/main/tools/install_bbfs_confidence_gate_2d3d_priority.sh | bash || true
# rem overfitting: turunkan agresivitas, pertahankan fokus 2D/3D belakang
sed -i \
  -e 's/frequency: 8,/frequency: 12,/g' \
  -e 's/trend_recent: 24,/trend_recent: 16,/g' \
  -e 's/ranking_2d: 20,/ranking_2d: 18,/g' \
  -e 's/ranking_3d: 20,/ranking_3d: 18,/g' \
  -e 's/back_focus: 18,/back_focus: 12,/g' \
  -e 's/adaptive_shift: 16,/adaptive_shift: 5,/g' \
  -e 's/gap_rebound: 5,/gap_rebound: 8,/g' \
  -e 's/confidence >= 45/confidence >= 50/g' \
  "$S"
# marker aman
cat >> "$S" <<'EOF'
// ANTI_OVERFIT_LITE_V1: trend pendek dan adaptive shift diturunkan; confidence AMAN minimal 50; fokus 2D/3D belakang tetap.
EOF
node -c "$S"
systemctl restart bbfs-backend
systemctl start bbfs-auto-statistika.service || true
echo "OK: anti-overfit lite aktif"
grep -n "ANTI_OVERFIT_LITE_V1\|trend_recent:\|adaptive_shift:\|confidence >= 50" "$S" | head -30
