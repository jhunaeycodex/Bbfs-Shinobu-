#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_active_only_public_counts.txt"
WEB_DIR="/var/www/jhunaey.my.id"
BACKEND_DIR="/opt/bbfs-shinobi/backend"
BASE_URL="https://jhunaey.my.id"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT HITUNGAN AKTIF SAJA UNTUK STATISTIK PUBLIK"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - tidak hapus/tidak ubah data"
  echo

  echo "=== 1. PHYSICAL VS ACTIVE ONLY COUNTS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_physical_result_draws FROM result_draws;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS active_only_results FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS inactive_archive_results FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=FALSE;"
  echo

  echo "=== 2. VALID/INVALID ACTIVE ONLY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS active_total, COUNT(*) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS active_valid_4d, COUNT(*) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS active_invalid_4d, MIN(r.draw_date) AS active_min_date, MAX(r.draw_date) AS active_max_date FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS inactive_total, COUNT(*) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS inactive_valid_4d, COUNT(*) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS inactive_invalid_4d, MIN(r.draw_date) AS inactive_min_date, MAX(r.draw_date) AS inactive_max_date FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=FALSE;"
  echo

  echo "=== 3. MERGED INACTIVE ARCHIVE IMPACT ==="
  sudo -u postgres psql -d bbfs_production -c "WITH old_codes AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), old_ids AS (SELECT m.id FROM markets m JOIN old_codes oc ON oc.code=m.code WHERE m.is_active=FALSE) SELECT (SELECT COUNT(*) FROM result_draws) AS physical_total, (SELECT COUNT(*) FROM result_draws WHERE market_id IN (SELECT id FROM old_ids)) AS merged_inactive_archive_rows, (SELECT COUNT(*) FROM result_draws WHERE market_id NOT IN (SELECT id FROM old_ids)) AS excluding_merged_inactive_archive;"
  echo

  echo "=== 4. ACTIVE MARKET COUNT DISTRIBUTION ==="
  sudo -u postgres psql -d bbfs_production -c "WITH c AS (SELECT m.id,m.code,m.name,COUNT(r.id) total FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name) SELECT COUNT(*) AS active_market, COUNT(*) FILTER (WHERE total=0) AS zero_result, COUNT(*) FILTER (WHERE total<30) AS below_30, COUNT(*) FILTER (WHERE total<1000) AS below_1000, COUNT(*) FILTER (WHERE total>=1000) AS gte_1000, SUM(total) AS active_total_rows FROM c;"
  echo

  echo "=== 5. PUBLIC/API COUNT RISK IN BACKEND SOURCE ==="
  if [ -f "$BACKEND_DIR/server.js" ]; then
    echo "COUNT(*) FROM result_draws refs:"
    grep -n "COUNT(\*)::int FROM result_draws\|COUNT(\*) FROM result_draws\|FROM result_draws" "$BACKEND_DIR/server.js" | head -80 || true
    echo
    echo "markets is_active refs near API:"
    grep -n "is_active" "$BACKEND_DIR/server.js" | head -80 || true
  else
    echo "MISSING backend/server.js"
  fi
  echo

  echo "=== 6. LIVE API SAMPLE DATA COUNTS ==="
  for url in "$BASE_URL/api/markets" "$BASE_URL/api/results/latest?limit=1" "$BASE_URL/api/public/bbfs-final-dashboard?limit=60"; do
    echo "URL=$url"
    curl -sk --max-time 30 "$url" | python3 -c 'import sys,json; raw=sys.stdin.read();
try:
 d=json.loads(raw); data=d.get("data");
 print("ok="+str(d.get("ok"))+" bytes="+str(len(raw))+" data_type="+type(data).__name__+" data_len="+str(len(data) if isinstance(data,list) else "n/a"))
except Exception as e:
 print("JSON_ERROR="+str(e)+" bytes="+str(len(raw)))' || true
  done
  echo

  echo "=== 7. FRONTEND DISPLAY SOURCE CHECK ==="
  if [ -f "$WEB_DIR/bbfs-home-final.js" ]; then
    grep -nF "/api/public/bbfs-final-dashboard" "$WEB_DIR/bbfs-home-final.js" || true
    grep -nF "/api/markets" "$WEB_DIR/bbfs-home-final.js" || true
    grep -nF "total" "$WEB_DIR/bbfs-home-final.js" | head -40 || true
  fi
  if [ -f "$WEB_DIR/result-card-live.js" ]; then
    grep -nF "/api/results/latest" "$WEB_DIR/result-card-live.js" || true
  fi
  echo

  echo "=== 8. RECOMMENDED PUBLIC METRIC QUERY ==="
  cat <<'SQL'
-- Gunakan ini untuk statistik publik:
SELECT COUNT(*) AS active_result_count
FROM result_draws r
JOIN markets m ON m.id = r.market_id
WHERE m.is_active = TRUE;

-- Jangan gunakan ini untuk statistik publik karena menghitung inactive archive juga:
SELECT COUNT(*) FROM result_draws;
SQL
  echo

  echo "=== 9. KESIMPULAN ==="
  echo "NO_DELETE_DONE=true"
  echo "PUBLIC_COUNT_SHOULD_USE=active markets only"
  echo "PHYSICAL_TOTAL_INCLUDES=active rows + inactive archive rows"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_active_only_public_counts.txt"
