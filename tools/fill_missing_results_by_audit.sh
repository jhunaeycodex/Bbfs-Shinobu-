#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
BACKEND="/opt/bbfs-shinobi/backend"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/fill_missing_results_by_audit.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
SOURCE_URL="${SOURCE_URL:-https://prediksi90.angka-alexis.pro/?page=data-keluaran-togel}"
DATE_FROM="${DATE_FROM:-2026-05-01}"
DATE_TO="${DATE_TO:-$(TZ=Asia/Jakarta date +%F)}"
mkdir -p "$REPORT_DIR"

{
  echo "FILL MISSING RESULTS BY AUDIT"
  echo "Generated: $STAMP"
  echo "Source: $SOURCE_URL"
  echo "Date range: $DATE_FROM to $DATE_TO"
  echo "Mode: source overwrite / insert missing / update mismatch"
  echo
  echo "=== BEFORE COUNT ACTIVE < 30 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<30 ORDER BY COUNT(r.id) ASC,LOWER(m.name);"
  echo
  echo "=== RUN DATE RANGE FETCH ALL ACTIVE ALIAS ==="
  cd "$BACKEND"
  SOURCE_URL="$SOURCE_URL" ALL_MARKETS=1 DATE_FROM="$DATE_FROM" DATE_TO="$DATE_TO" node scripts/manual_fetch_date_range_worker.js "$SOURCE_URL" "__ALL__" "$DATE_FROM" "$DATE_TO"
  echo
  echo "=== AFTER TOTAL SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_result,COUNT(DISTINCT market_id) AS market_punya_result,MIN(draw_date) AS tanggal_awal,MAX(draw_date) AS tanggal_akhir,COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d,COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d FROM result_draws;"
  echo
  echo "=== AFTER COUNT ACTIVE < 30 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir,COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') AS result_30_hari FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<30 ORDER BY COUNT(r.id) ASC,LOWER(m.name);"
  echo
  echo "=== AFTER ACTIVE MARKET LATEST BEHIND > 2 DAYS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MAX(r.draw_date) AS latest_tanggal,(CURRENT_DATE - MAX(r.draw_date)) AS tertinggal_hari FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING MAX(r.draw_date)<CURRENT_DATE-INTERVAL '2 day' OR MAX(r.draw_date) IS NULL ORDER BY latest_tanggal NULLS FIRST,LOWER(m.name);"
  echo
  echo "=== AFTER ACTIVE RESULT 30 DAYS < 10 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') AS result_30_hari,COUNT(r.id) AS total_result,MAX(r.draw_date) AS latest_tanggal FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') < 10 ORDER BY result_30_hari ASC,total_result ASC,LOWER(m.name);"
  echo
  echo "=== AFTER BBFS ACTIVE STATUS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT user_status,prediction_status,can_show_prediction,COUNT(*) jumlah,ROUND(AVG(confidence)::numeric,2) avg_confidence,MIN(confidence) min_confidence,MAX(confidence) max_confidence FROM latest GROUP BY user_status,prediction_status,can_show_prediction ORDER BY user_status,prediction_status;"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/fill_missing_results_by_audit.txt"
