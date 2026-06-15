#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/hold_active_only.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$REPORT_DIR"

{
  echo "BBFS HOLD ACTIVE ONLY REPORT"
  echo "Generated: $STAMP"
  echo
  echo "=== ACTIVE MARKET DISTRIBUTION ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT user_status,prediction_status,can_show_prediction,COUNT(*) jumlah,ROUND(AVG(confidence)::numeric,2) avg_confidence,MIN(confidence) min_confidence,MAX(confidence) max_confidence FROM latest GROUP BY user_status,prediction_status,can_show_prediction ORDER BY user_status,prediction_status;"
  echo
  echo "=== ACTIVE HOLD DETAIL ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at,p.gate_json FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT m.name,m.code,m.is_active,l.user_status,l.prediction_status,l.can_show_prediction,l.confidence,l.gate_json->'prediction_gate'->'errors' AS errors FROM latest l JOIN markets m ON m.id=l.market_id WHERE l.user_status='HOLD' ORDER BY l.confidence ASC;"
  echo
  echo "=== INACTIVE HOLD DETAIL ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at,p.gate_json FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=false ORDER BY p.market_id,p.updated_at DESC) SELECT m.name,m.code,m.is_active,l.user_status,l.prediction_status,l.can_show_prediction,l.confidence,l.updated_at FROM latest l JOIN markets m ON m.id=l.market_id WHERE l.user_status='HOLD' ORDER BY l.confidence ASC;"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/hold_active_only.txt"
