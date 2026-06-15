#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_1_month_result_per_market_sync.txt"
BASE_URL="https://jhunaey.my.id"
DAYS_BACK="${DAYS_BACK:-30}"
mkdir -p "$REPORT_DIR"

psqlq(){ sudo -u postgres psql -d bbfs_production "$@"; }

{
  echo "AUDIT 1 BULAN DATA RESULT PER PASARAN"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - tidak fetch update, tidak hapus, tidak ubah data"
  echo "Window: CURRENT_DATE - $DAYS_BACK sampai CURRENT_DATE"
  echo

  echo "=== 1. DEFINISI SINKRON 1 BULAN ==="
  echo "Sinkron yang dicek: setiap active market punya data result dalam window 1 bulan, source label tidak kosong, latest DB cocok dengan API, dan mapping source tersedia jika ada."
  echo "Catatan: pasar yang memang belum tersedia 1 bulan akan muncul sebagai kurang/missing; audit ini belum membandingkan live ke website sumber eksternal."
  echo

  echo "=== 2. SUMMARY ACTIVE MARKET 1 BULAN ==="
  psqlq -c "WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), dates AS (SELECT generate_series((SELECT start_date FROM params),(SELECT end_date FROM params),'1 day')::date d), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), c AS (SELECT a.id,a.code,a.name,COUNT(r.id) AS rows_1m,COUNT(DISTINCT r.draw_date) AS dates_with_result,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date,COUNT(r.id) FILTER (WHERE r.source IS NULL OR TRIM(r.source)='') AS blank_source_rows FROM active a LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date BETWEEN (SELECT start_date FROM params) AND (SELECT end_date FROM params) GROUP BY a.id,a.code,a.name), m AS (SELECT c.*, (SELECT COUNT(*) FROM dates)::int AS expected_calendar_days, ((SELECT COUNT(*) FROM dates)::int - c.dates_with_result) AS missing_calendar_days FROM c) SELECT COUNT(*) AS active_markets, SUM(rows_1m) AS total_rows_1m, COUNT(*) FILTER (WHERE rows_1m=0) AS zero_rows_1m, COUNT(*) FILTER (WHERE dates_with_result>=30) AS markets_with_30_plus_dates, COUNT(*) FILTER (WHERE dates_with_result<30) AS markets_below_30_dates, COUNT(*) FILTER (WHERE blank_source_rows>0) AS markets_with_blank_source FROM m;"
  echo

  echo "=== 3. DETAIL PER PASARAN ACTIVE 1 BULAN ==="
  psqlq -c "WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), dates AS (SELECT generate_series((SELECT start_date FROM params),(SELECT end_date FROM params),'1 day')::date d), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), c AS (SELECT a.id,a.code,a.name,COUNT(r.id) AS rows_1m,COUNT(DISTINCT r.draw_date) AS dates_with_result,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date,COUNT(r.id) FILTER (WHERE r.source IS NULL OR TRIM(r.source)='') AS blank_source_rows,STRING_AGG(DISTINCT COALESCE(NULLIF(SPLIT_PART(r.source,':',1),''),'[blank]'), ', ' ORDER BY COALESCE(NULLIF(SPLIT_PART(r.source,':',1),''),'[blank]')) AS source_families FROM active a LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date BETWEEN (SELECT start_date FROM params) AND (SELECT end_date FROM params) GROUP BY a.id,a.code,a.name), m AS (SELECT c.*, (SELECT COUNT(*) FROM dates)::int AS expected_calendar_days, ((SELECT COUNT(*) FROM dates)::int - c.dates_with_result) AS missing_calendar_days FROM c) SELECT code,name,rows_1m,dates_with_result,missing_calendar_days,blank_source_rows,min_date,max_date,source_families FROM m ORDER BY missing_calendar_days DESC,rows_1m ASC,code;"
  echo

  echo "=== 4. PASARAN ACTIVE YANG KURANG DARI 30 TANGGAL RESULT DALAM 1 BULAN ==="
  psqlq -c "WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), c AS (SELECT a.id,a.code,a.name,COUNT(DISTINCT r.draw_date) AS dates_with_result,COUNT(r.id) AS rows_1m,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date FROM active a LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date BETWEEN (SELECT start_date FROM params) AND (SELECT end_date FROM params) GROUP BY a.id,a.code,a.name) SELECT code,name,rows_1m,dates_with_result,min_date,max_date FROM c WHERE dates_with_result<30 ORDER BY dates_with_result,code;"
  echo

  echo "=== 5. MISSING DATE SAMPLE PER PASARAN KURANG ==="
  psqlq -c "WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), dates AS (SELECT generate_series((SELECT start_date FROM params),(SELECT end_date FROM params),'1 day')::date d), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), missing AS (SELECT a.code,a.name,d.d AS missing_date FROM active a CROSS JOIN dates d LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date=d.d WHERE r.id IS NULL), agg AS (SELECT code,name,COUNT(*) AS missing_count,STRING_AGG(TO_CHAR(missing_date,'YYYY-MM-DD'), ', ' ORDER BY missing_date) AS missing_dates FROM missing GROUP BY code,name) SELECT code,name,missing_count,LEFT(missing_dates,500) AS missing_dates_sample FROM agg WHERE missing_count>0 ORDER BY missing_count DESC,code LIMIT 100;"
  echo

  echo "=== 6. LATEST DB VS API SAMPLE ==="
  for code in singapore florida-eve ohio-eve totomacau-22 taiwan tennesse-eve texas-eve; do
    db=$(psqlq -t -A -F '|' -c "SELECT TO_CHAR(r.draw_date,'YYYY-MM-DD')||'|'||r.result||'|'||COALESCE(r.source,'') FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code='$code' ORDER BY r.draw_date DESC,r.id DESC LIMIT 1;" | sed 's/[[:space:]]//g')
    api=$(curl -sk --max-time 20 "$BASE_URL/api/results/latest?limit=1&market_code=$code" | python3 -c 'import sys,json; d=json.load(sys.stdin); x=d.get("data") or []; print((x[0].get("draw_date","")+"|"+str(x[0].get("result",""))) if x else "NO_DATA")' 2>/dev/null || echo "API_ERROR")
    db_key=$(echo "$db" | cut -d'|' -f1,2)
    status="MISMATCH"
    [ "$db_key" = "$api" ] && status="MATCH"
    echo "LATEST_1M_CHECK|$code|DB=$db|API=$api|$status"
  done
  echo

  echo "=== 7. SOURCE MAPPING COVERAGE PER ACTIVE MARKET ==="
  psqlq -c "WITH active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), map AS (SELECT canonical_market_id,COUNT(*) AS alias_rows,COUNT(*) FILTER (WHERE is_active=TRUE) AS active_alias_rows,STRING_AGG(DISTINCT source_url, ' | ' ORDER BY source_url) AS source_urls FROM market_source_aliases GROUP BY canonical_market_id) SELECT a.code,a.name,COALESCE(map.alias_rows,0) AS alias_rows,COALESCE(map.active_alias_rows,0) AS active_alias_rows,COALESCE(map.source_urls,'') AS source_urls FROM active a LEFT JOIN map ON map.canonical_market_id=a.id ORDER BY active_alias_rows ASC,a.code;" || echo "market_source_aliases belum tersedia/struktur berbeda"
  echo

  echo "=== 8. SOURCE FAMILY 1 BULAN ACTIVE ==="
  psqlq -c "SELECT COALESCE(NULLIF(SPLIT_PART(r.source,':',1),''),'[blank]') AS source_family,COUNT(*) AS rows_1m,COUNT(DISTINCT m.code) AS markets FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE AND r.draw_date BETWEEN CURRENT_DATE-$DAYS_BACK AND CURRENT_DATE GROUP BY 1 ORDER BY rows_1m DESC;"
  echo

  echo "=== 9. EXPORT CSV DETAIL ==="
  CSV1="$REPORT_DIR/active_1_month_market_coverage.csv"
  CSV2="$REPORT_DIR/active_1_month_missing_dates.csv"
  psqlq -c "COPY (WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), dates AS (SELECT generate_series((SELECT start_date FROM params),(SELECT end_date FROM params),'1 day')::date d), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE), c AS (SELECT a.id,a.code,a.name,COUNT(r.id) AS rows_1m,COUNT(DISTINCT r.draw_date) AS dates_with_result,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date,COUNT(r.id) FILTER (WHERE r.source IS NULL OR TRIM(r.source)='') AS blank_source_rows,STRING_AGG(DISTINCT COALESCE(NULLIF(SPLIT_PART(r.source,':',1),''),'[blank]'), ', ' ORDER BY COALESCE(NULLIF(SPLIT_PART(r.source,':',1),''),'[blank]')) AS source_families FROM active a LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date BETWEEN (SELECT start_date FROM params) AND (SELECT end_date FROM params) GROUP BY a.id,a.code,a.name), m AS (SELECT c.*, (SELECT COUNT(*) FROM dates)::int AS expected_calendar_days, ((SELECT COUNT(*) FROM dates)::int - c.dates_with_result) AS missing_calendar_days FROM c) SELECT code,name,rows_1m,dates_with_result,missing_calendar_days,blank_source_rows,min_date,max_date,source_families FROM m ORDER BY missing_calendar_days DESC,rows_1m ASC,code) TO '$CSV1' CSV HEADER;"
  psqlq -c "COPY (WITH params AS (SELECT (CURRENT_DATE - $DAYS_BACK)::date start_date, CURRENT_DATE::date end_date), dates AS (SELECT generate_series((SELECT start_date FROM params),(SELECT end_date FROM params),'1 day')::date d), active AS (SELECT id,code,name FROM markets WHERE is_active=TRUE) SELECT a.code,a.name,d.d AS missing_date FROM active a CROSS JOIN dates d LEFT JOIN result_draws r ON r.market_id=a.id AND r.draw_date=d.d WHERE r.id IS NULL ORDER BY a.code,d.d) TO '$CSV2' CSV HEADER;"
  ls -lh "$CSV1" "$CSV2" || true
  echo

  echo "=== 10. KESIMPULAN FLAG ==="
  echo "NO_WRITE_DONE=true"
  echo "ONE_MONTH_PER_MARKET_AUDIT=true"
  echo "SYNC_RULE=active market should have roughly 30 dates in the last month, no blank source, and latest API must match DB."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_1_month_result_per_market_sync.txt"
