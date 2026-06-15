#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/db_repair_invalid_result_4d.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
CSV_BACKUP="$REPORT_DIR/invalid_result_4d_backup_$(date +%Y%m%d_%H%M%S).csv"
mkdir -p "$REPORT_DIR"

{
  echo "DB REPAIR INVALID RESULT 4D"
  echo "Generated: $STAMP"
  echo "CSV backup: $CSV_BACKUP"
  echo
  echo "=== BEFORE SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS result_total FROM result_draws;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS invalid_result_4d FROM result_draws WHERE result IS NULL OR result !~ '^[0-9]{4}$';"
  echo
  echo "=== INVALID SAMPLE BEFORE ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT r.id,m.code,m.name,r.draw_date,r.result,r.source,LEFT(COALESCE(r.raw_payload::text,''),160) AS raw_payload FROM result_draws r LEFT JOIN markets m ON m.id=r.market_id WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$' ORDER BY r.draw_date DESC NULLS LAST,r.id DESC LIMIT 100;"
  echo
  echo "=== BACKUP CSV ==="
  sudo -u postgres psql -d bbfs_production -c "\\copy (SELECT r.*,m.code AS market_code,m.name AS market_name FROM result_draws r LEFT JOIN markets m ON m.id=r.market_id WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$' ORDER BY r.draw_date DESC NULLS LAST,r.id DESC) TO '$CSV_BACKUP' CSV HEADER"
  ls -lh "$CSV_BACKUP"
  echo
  echo "=== CREATE QUARANTINE TABLE ==="
  sudo -u postgres psql -d bbfs_production -c "CREATE TABLE IF NOT EXISTS result_draws_invalid_4d_quarantine AS SELECT r.*,now() AS quarantined_at,'invalid_4d_before_repair'::text AS quarantine_reason FROM result_draws r WHERE false;"
  echo
  echo "=== INSERT TO QUARANTINE ==="
  sudo -u postgres psql -d bbfs_production -c "INSERT INTO result_draws_invalid_4d_quarantine SELECT r.*,now() AS quarantined_at,'invalid_4d_before_repair'::text AS quarantine_reason FROM result_draws r WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$';"
  echo
  echo "=== DELETE INVALID FROM MAIN RESULT TABLE ==="
  sudo -u postgres psql -d bbfs_production -c "DELETE FROM result_draws WHERE result IS NULL OR result !~ '^[0-9]{4}$';"
  echo
  echo "=== ANALYZE ==="
  sudo -u postgres psql -d bbfs_production -c "ANALYZE result_draws;"
  echo
  echo "=== AFTER SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS result_total FROM result_draws;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS invalid_result_4d FROM result_draws WHERE result IS NULL OR result !~ '^[0-9]{4}$';"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS quarantine_total FROM result_draws_invalid_4d_quarantine;"
  echo
  echo "=== ACTIVE MARKET LATEST RESULT BEHIND AFTER ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,MAX(r.draw_date) AS latest_tanggal FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING MAX(r.draw_date)<CURRENT_DATE-INTERVAL '2 day' OR MAX(r.draw_date) IS NULL ORDER BY latest_tanggal NULLS FIRST,LOWER(m.name) LIMIT 50;"
  echo
  echo "=== BBFS ACTIVE STATUS AFTER ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT user_status,prediction_status,can_show_prediction,COUNT(*) jumlah,ROUND(AVG(confidence)::numeric,2) avg_confidence,MIN(confidence) min_confidence,MAX(confidence) max_confidence FROM latest GROUP BY user_status,prediction_status,can_show_prediction ORDER BY user_status,prediction_status;"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/db_repair_invalid_result_4d.txt"
