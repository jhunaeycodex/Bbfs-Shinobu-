#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/hold_latest.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

mkdir -p "$REPORT_DIR"

{
  echo "BBFS HOLD LATEST REPORT"
  echo "Generated: $STAMP"
  echo
  echo "=== DISTRIBUSI LATEST PER PASARAN ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (market_id) market_id,user_status,prediction_status,can_show_prediction,confidence,updated_at FROM bbfs_final_next_draw_predictions ORDER BY market_id,updated_at DESC) SELECT user_status,prediction_status,can_show_prediction,COUNT(*) jumlah,ROUND(AVG(confidence)::numeric,2) avg_confidence,MIN(confidence) min_confidence,MAX(confidence) max_confidence FROM latest GROUP BY user_status,prediction_status,can_show_prediction ORDER BY user_status,prediction_status;"
  echo
  echo "=== DAFTAR HOLD LATEST ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (market_id) market_id,user_status,prediction_status,can_show_prediction,confidence,updated_at FROM bbfs_final_next_draw_predictions ORDER BY market_id,updated_at DESC) SELECT m.name,m.code,l.user_status,l.prediction_status,l.can_show_prediction,l.confidence,l.updated_at FROM latest l JOIN markets m ON m.id=l.market_id WHERE l.user_status='HOLD' ORDER BY l.confidence ASC;"
  echo
  echo "=== DETAIL ERROR GATE UNTUK HOLD ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at,p.gate_json FROM bbfs_final_next_draw_predictions p ORDER BY p.market_id,p.updated_at DESC) SELECT m.name,m.code,l.confidence,l.gate_json->'prediction_gate'->'errors' AS errors,l.gate_json->'data_cutoff' AS data_cutoff FROM latest l JOIN markets m ON m.id=l.market_id WHERE l.user_status='HOLD' ORDER BY l.confidence ASC;"
} > "$REPORT_FILE"

cat "$REPORT_FILE"

bbfs-push-github || true

echo
echo "REPORT_SAVED=$REPORT_FILE"
echo "REPORT_PUSHED_TO_GITHUB=reports/hold_latest.txt"
