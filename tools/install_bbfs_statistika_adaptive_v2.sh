#!/usr/bin/env bash
set -euo pipefail
S=/opt/bbfs-shinobi/backend/server.js
[ -f "$S" ] || { echo "GAGAL: $S tidak ditemukan"; exit 1; }
cp "$S" "$S.bak-statistika-v2-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/bbfs-shinobi/backend/server.js')
s=p.read_text(encoding='utf-8')
if 'STATISTIKA_ADAPTIVE_V2' in s:
    print('Sudah terpasang: STATISTIKA_ADAPTIVE_V2')
    raise SystemExit
s=s.replace('function finalBuildScoring(draws) {','function finalBuildScoring(draws, adaptiveStats = {}) {',1)
s=s.replace("""  const weights = {
    frequency: 20,
    poltar_position: 20,
    trend_recent: 15,
    ranking_2d: 10,
    ranking_3d: 10,
    gap_rebound: 10,
    twin: 5,
    miss: 5,
    san: 5
  };""","""  const weights = {
    frequency: 8,
    poltar_position: 16,
    trend_recent: 24,
    ranking_2d: 20,
    ranking_3d: 20,
    back_focus: 18,
    adaptive_shift: 16,
    gap_rebound: 5,
    twin: 2,
    miss: 3,
    san: 3
  };

  if ((adaptiveStats.evaluated_count || 0) >= 5) {
    if ((adaptiveStats.hit_2d_rate || 0) < 0.45) weights.ranking_2d += 4;
    if ((adaptiveStats.hit_3d_rate || 0) < 0.30) weights.ranking_3d += 4;
    if ((adaptiveStats.bbfs_hit_rate || 0) < 0.30) {
      weights.frequency = Math.max(4, weights.frequency - 3);
      weights.trend_recent += 3;
      weights.adaptive_shift += 3;
    }
  }""",1)
s=s.replace("""      gap_score: 0,
      twin_score: 0,""","""      gap_score: 0,
      back_focus_score: 0,
      adaptive_shift_score: 0,
      twin_score: 0,""",1)
s=s.replace("""    const r2 = r4.slice(-2);
    const r3 = r4.slice(-3);""","""    const r2 = r4.slice(-2);
    const r3 = r4.slice(-3);
    const recent10Boost = index < 10 ? (10 - index) / 10 : 0;
    const recent5Boost = index < 5 ? (5 - index) / 5 : 0;

    r2.split('').forEach(d => {
      digitStats[d].back_focus_score += recent10Boost * 2.2;
      digitStats[d].adaptive_shift_score += recent5Boost * 2.6;
    });
    r3.split('').forEach(d => {
      digitStats[d].back_focus_score += recent10Boost * 1.8;
      digitStats[d].adaptive_shift_score += recent5Boost * 1.8;
    });""",1)
s=s.replace("""  const maxGap = max(digits.map(d => digitStats[d].gap_score));
  const maxTwin = max(digits.map(d => digitStats[d].twin_score));""","""  const maxGap = max(digits.map(d => digitStats[d].gap_score));
  const maxBackFocus = max(digits.map(d => digitStats[d].back_focus_score));
  const maxAdaptiveShift = max(digits.map(d => digitStats[d].adaptive_shift_score));
  const maxTwin = max(digits.map(d => digitStats[d].twin_score));""",1)
s=s.replace("""      (x.ranking_3d_score / maxR3) * weights.ranking_3d +
      (x.gap_score / maxGap) * weights.gap_rebound +""","""      (x.ranking_3d_score / maxR3) * weights.ranking_3d +
      (x.back_focus_score / maxBackFocus) * weights.back_focus +
      (x.adaptive_shift_score / maxAdaptiveShift) * weights.adaptive_shift +
      (x.gap_score / maxGap) * weights.gap_rebound +""",1)
s=s.replace("""      gap_score: Number(x.gap_score.toFixed(4)),
      twin_score: Number(x.twin_score.toFixed(4)),""","""      gap_score: Number(x.gap_score.toFixed(4)),
      back_focus_score: Number(x.back_focus_score.toFixed(4)),
      adaptive_shift_score: Number(x.adaptive_shift_score.toFixed(4)),
      twin_score: Number(x.twin_score.toFixed(4)),""",1)
s=s.replace("""    weights,
    scoredDigits,""","""    formula_upgrade: 'STATISTIKA_ADAPTIVE_V2',
    adaptive_stats: adaptiveStats,
    weights,
    scoredDigits,""",1)
helper="""
async function finalLoadAdaptiveStats(marketId) {
  const result = await pool.query(`
    SELECT evaluation_json
    FROM bbfs_final_next_draw_predictions
    WHERE market_id = $1
      AND evaluation_json->>'status' = 'EVALUATED'
    ORDER BY next_draw_date DESC
    LIMIT 30
  `, [marketId]);

  const rows = result.rows.map(r => r.evaluation_json || {});
  const n = rows.length;
  const rate = key => n ? rows.filter(x => x[key] === true).length / n : 0;

  return {
    formula_upgrade: 'STATISTIKA_ADAPTIVE_V2',
    evaluated_count: n,
    bbfs_hit_rate: Number(rate('bbfs_hit').toFixed(4)),
    hit_2d_rate: Number(rate('hit_2d').toFixed(4)),
    hit_3d_rate: Number(rate('hit_3d').toFixed(4)),
    note: 'Evaluasi hit/miss dipakai untuk koreksi bobot 2D, 3D, trend, dan frekuensi.'
  };
}
"""
s=s.replace('async function finalGeneratePrediction(marketCodeInput, inputLimit, forcedNextDate) {',helper+'\nasync function finalGeneratePrediction(marketCodeInput, inputLimit, forcedNextDate) {',1)
s=s.replace('  const score = finalBuildScoring(draws);','  const adaptiveStats = await finalLoadAdaptiveStats(market.id);\n  const score = finalBuildScoring(draws, adaptiveStats);',1)
s=s.replace("""      formula: 'FORMULA_V1_FINAL_LOCKED',
      mode: 'BBFS_AUTOMATIC_NEXT_DRAW_FINAL',""","""      formula: 'FORMULA_V1_FINAL_LOCKED_STATISTIKA_ADAPTIVE_V2',
      mode: 'BBFS_AUTOMATIC_NEXT_DRAW_FINAL',
      statistika_adaptive_v2: score.adaptive_stats,""",1)
p.write_text(s,encoding='utf-8')
PY
node -c "$S"
systemctl restart bbfs-backend
systemctl start bbfs-auto-statistika.service || true
echo "OK: BBFS Statistika Adaptive V2 aktif"
echo "Cek: tail -60 /var/log/bbfs-auto-statistika.log"
