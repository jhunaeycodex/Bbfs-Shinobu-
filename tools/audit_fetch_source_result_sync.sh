#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_fetch_source_result_sync.txt"
WEB_DIR="/var/www/jhunaey.my.id"
BACKEND_DIR="/opt/bbfs-shinobi/backend"
BASE_URL="https://jhunaey.my.id"
mkdir -p "$REPORT_DIR"

psqlq(){ sudo -u postgres psql -d bbfs_production "$@"; }

{
  echo "AUDIT RESULT SINKRON DENGAN SOURCE FETCH"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - tidak fetch update, tidak hapus, tidak ubah data"
  echo

  echo "=== 1. TUJUAN AUDIT ==="
  echo "Cek apakah result database memiliki jejak source/fetch yang jelas, market aktif punya source URL/mapping, dan API/result frontend membaca database hasil fetch."
  echo "Catatan: audit ini tidak membandingkan ulang ke website sumber eksternal secara live agar tidak menulis/mengubah data."
  echo

  echo "=== 2. DATABASE RESULT SUMMARY ==="
  psqlq -c "SELECT COUNT(*) AS total_results, COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d, COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d, MIN(draw_date) AS min_date, MAX(draw_date) AS max_date FROM result_draws;"
  psqlq -c "SELECT COUNT(*) AS active_results FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE;"
  psqlq -c "SELECT COUNT(*) AS inactive_archive_results FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=FALSE;"
  echo

  echo "=== 3. SOURCE FIELD COVERAGE DI result_draws ==="
  psqlq -c "SELECT COUNT(*) AS total_rows, COUNT(*) FILTER (WHERE source IS NULL OR TRIM(source)='') AS blank_source, COUNT(*) FILTER (WHERE source IS NOT NULL AND TRIM(source)<>'') AS has_source FROM result_draws;"
  psqlq -c "SELECT COALESCE(NULLIF(SPLIT_PART(source,':',1),''),'[blank]') AS source_family, COUNT(*) AS rows FROM result_draws GROUP BY 1 ORDER BY rows DESC LIMIT 50;"
  echo

  echo "=== 4. SOURCE COVERAGE ACTIVE ONLY ==="
  psqlq -c "SELECT COUNT(*) AS active_rows, COUNT(*) FILTER (WHERE r.source IS NULL OR TRIM(r.source)='') AS active_blank_source, COUNT(*) FILTER (WHERE r.source IS NOT NULL AND TRIM(r.source)<>'') AS active_has_source FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE;"
  psqlq -c "SELECT m.code,m.name,COUNT(*) AS total_rows,COUNT(*) FILTER (WHERE r.source IS NULL OR TRIM(r.source)='') AS blank_source,COUNT(*) FILTER (WHERE r.source IS NOT NULL AND TRIM(r.source)<>'') AS has_source,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE GROUP BY m.code,m.name ORDER BY blank_source DESC,total_rows DESC,m.code LIMIT 80;"
  echo

  echo "=== 5. MARKET SOURCE URL / OFFICIAL URL COVERAGE ==="
  echo "Kolom yang tersedia pada markets:"
  psqlq -c "SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='markets' ORDER BY ordinal_position;"
  echo
  echo "Kolom yang tersedia pada market_profiles jika ada:"
  psqlq -c "SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='market_profiles' ORDER BY ordinal_position;" || true
  echo
  echo "URL-like columns aktif pada markets:"
  psqlq -c "SELECT code,name,is_active,official_url,source_url,website_url FROM markets WHERE is_active=TRUE ORDER BY code;" || echo "markets tidak punya salah satu kolom official_url/source_url/website_url"
  echo

  echo "=== 6. FETCH / IMPORT TABLE COVERAGE ==="
  psqlq -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%fetch%' OR table_name ILIKE '%import%' OR table_name ILIKE '%source%' OR table_name ILIKE '%alias%') ORDER BY table_name;"
  echo
  for t in fetch_batches fetch_logs import_batches import_errors market_aliases market_source_aliases source_market_aliases; do
    exists=$(psqlq -t -A -c "SELECT to_regclass('public.$t') IS NOT NULL;" | tr -d '[:space:]')
    if [ "$exists" = "t" ]; then
      echo "TABLE_EXISTS|$t"
      psqlq -c "SELECT COUNT(*) AS rows FROM $t;" || true
      psqlq -c "SELECT * FROM $t ORDER BY 1 DESC LIMIT 5;" || true
    fi
  done
  echo

  echo "=== 7. ACTIVE LATEST DB VS API ==="
  for code in singapore florida-eve ohio-eve totomacau-22 taiwan tennesse-eve texas-eve; do
    db=$(psqlq -t -A -F '|' -c "SELECT TO_CHAR(r.draw_date,'YYYY-MM-DD')||'|'||r.result||'|'||COALESCE(r.source,'') FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code='$code' ORDER BY r.draw_date DESC,r.id DESC LIMIT 1;" | sed 's/[[:space:]]//g')
    api=$(curl -sk --max-time 20 "$BASE_URL/api/results/latest?limit=1&market_code=$code" | python3 -c 'import sys,json; d=json.load(sys.stdin); x=d.get("data") or []; print((x[0].get("draw_date","")+"|"+str(x[0].get("result",""))) if x else "NO_DATA")' 2>/dev/null || echo "API_ERROR")
    db_key=$(echo "$db" | cut -d'|' -f1,2)
    status="MISMATCH"
    [ "$db_key" = "$api" ] && status="MATCH"
    echo "LATEST_SOURCE_CHECK|$code|DB=$db|API=$api|$status"
  done
  echo

  echo "=== 8. ACTIVE LATEST SOURCE FAMILY ==="
  psqlq -c "WITH latest AS (SELECT DISTINCT ON (m.id) m.code,m.name,r.draw_date,r.result,r.source FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE ORDER BY m.id,r.draw_date DESC,r.id DESC) SELECT COALESCE(NULLIF(SPLIT_PART(source,':',1),''),'[blank]') AS source_family,COUNT(*) AS active_latest_markets FROM latest GROUP BY 1 ORDER BY active_latest_markets DESC;"
  psqlq -c "WITH latest AS (SELECT DISTINCT ON (m.id) m.code,m.name,r.draw_date,r.result,r.source FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE ORDER BY m.id,r.draw_date DESC,r.id DESC) SELECT * FROM latest WHERE source IS NULL OR TRIM(source)='' ORDER BY code LIMIT 100;"
  echo

  echo "=== 9. FETCH CODE PATH EVIDENCE ==="
  if [ -f "$BACKEND_DIR/server.js" ]; then
    echo "manual fetch routes:"
    grep -n "manual-fetch\|manual-result\|market-alias\|source_url\|fetch" "$BACKEND_DIR/server.js" | head -160 || true
    echo
    echo "insert/update result_draws routes:"
    grep -n "INSERT INTO result_draws\|ON CONFLICT\|UPDATE result_draws\|DELETE FROM result_draws" "$BACKEND_DIR/server.js" | head -120 || true
  else
    echo "MISSING backend/server.js"
  fi
  echo

  echo "=== 10. FRONTEND FETCH SOURCE UI EVIDENCE ==="
  for f in manual-fetch.html result-card-live.js bbfs-home-final.js; do
    if [ -f "$WEB_DIR/$f" ]; then
      echo "FILE=$f"
      grep -n "/api/.*fetch\|manual-fetch\|source_url\|/api/results/latest\|/api/markets" "$WEB_DIR/$f" | head -120 || true
    else
      echo "MISSING|$f"
    fi
  done
  echo

  echo "=== 11. RISIKO SINKRON SOURCE ==="
  echo "Jika blank_source > 0: data ada di DB tetapi tidak semua row memiliki label source."
  echo "Jika active latest source blank: latest result aktif perlu audit sumber/import batch."
  echo "Jika market source_url kosong: fetch masih bisa jalan lewat input manual source, tapi mapping sumber resmi belum terkunci di DB."
  echo

  echo "=== 12. KESIMPULAN FLAG ==="
  echo "NO_WRITE_DONE=true"
  echo "SOURCE_SYNC_AUDIT_ONLY=true"
  echo "NEXT_SAFE_STEP=review blank source, active latest source, and source_url coverage; then decide whether to lock source mapping table."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_fetch_source_result_sync.txt"
