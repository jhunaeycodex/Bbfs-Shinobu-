#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_system_reads_database.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
BACKEND_DIR="/opt/bbfs-shinobi/backend"
WEB_DIR="/var/www/jhunaey.my.id"
BASE_URL="https://jhunaey.my.id"
mkdir -p "$REPORT_DIR"

api_get(){
  local url="$1"
  echo "URL: $url"
  curl -sk --max-time 20 "$url" | python3 - <<'PY'
import sys,json
raw=sys.stdin.read()
print(raw[:2000])
try:
    data=json.loads(raw)
    print('\nJSON_KEYS:', list(data.keys()) if isinstance(data,dict) else type(data).__name__)
except Exception as e:
    print('\nJSON_PARSE_ERROR:', e)
PY
}

{
  echo "AUDIT SISTEM BBFS DAN RESULT MEMBACA DATABASE"
  echo "Generated: $STAMP"
  echo "Mode: READ ONLY - tidak mengubah database"
  echo

  echo "=== 1. SERVICE STATUS ==="
  systemctl is-active bbfs-backend || true
  systemctl is-active nginx || true
  echo

  echo "=== 2. DATABASE COUNTS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_markets,COUNT(*) FILTER (WHERE is_active=TRUE) AS active_markets FROM markets;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_results,COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d,COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d,MIN(draw_date) AS tanggal_awal,MAX(draw_date) AS tanggal_akhir FROM result_draws;"
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.code IN ('singapore','taiwan','totomacau-22','florida-eve','ohio-eve') GROUP BY m.id,m.code,m.name ORDER BY m.code;"
  echo

  echo "=== 3. DB LATEST RESULT SAMPLE ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,r.draw_date,r.result,r.source FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code IN ('singapore','taiwan','totomacau-22','florida-eve','ohio-eve') ORDER BY m.code,r.draw_date DESC,r.id DESC LIMIT 15;"
  echo

  echo "=== 4. API RESULT SAMPLE - HARUS SAMA DENGAN DB LATEST ==="
  for code in singapore taiwan totomacau-22 florida-eve ohio-eve; do
    echo "--- API latest for $code ---"
    curl -sk --max-time 20 "$BASE_URL/api/results/latest?market_code=$code" | head -c 1500
    echo
  done
  echo

  echo "=== 5. API MARKETS SAMPLE ==="
  curl -sk --max-time 20 "$BASE_URL/api/markets" | head -c 2000
  echo
  echo

  echo "=== 6. API BBFS / DASHBOARD SAMPLE ==="
  echo "--- /api/public/bbfs-final-dashboard?limit=5 ---"
  curl -sk --max-time 20 "$BASE_URL/api/public/bbfs-final-dashboard?limit=5" | head -c 3000
  echo
  echo
  echo "--- /api/public/bbfs-final-dashboard?market_code=singapore&limit=3 ---"
  curl -sk --max-time 20 "$BASE_URL/api/public/bbfs-final-dashboard?market_code=singapore&limit=3" | head -c 3000
  echo
  echo

  echo "=== 7. BACKEND CODE CHECK: DATABASE TABLE REFERENCES ==="
  if [ -d "$BACKEND_DIR" ]; then
    echo "Backend dir: $BACKEND_DIR"
    echo "--- result_draws refs ---"
    grep -RIn --exclude-dir=node_modules --exclude='*.log' "result_draws" "$BACKEND_DIR" | head -80 || true
    echo "--- bbfs/final/prediction refs ---"
    grep -RIn --exclude-dir=node_modules --exclude='*.log' -E "bbfs|prediction|final_predictions|bbfs_predictions|prediction_runs|digit_scores" "$BACKEND_DIR" | head -120 || true
    echo "--- database client refs ---"
    grep -RIn --exclude-dir=node_modules --exclude='*.log' -E "Pool\(|pg\.|pool\.query|db\.query|DATABASE_URL|postgres|bbfs_production" "$BACKEND_DIR" | head -120 || true
  else
    echo "Backend dir not found: $BACKEND_DIR"
  fi
  echo

  echo "=== 8. FRONTEND CHECK: API VS HARDCODE ==="
  if [ -d "$WEB_DIR" ]; then
    echo "Web dir: $WEB_DIR"
    echo "--- API calls in frontend ---"
    grep -RIn --exclude-dir=node_modules --exclude='*.map' -E "/api/|fetch\(|axios|XMLHttpRequest" "$WEB_DIR" | head -120 || true
    echo "--- possible static hardcoded result files ---"
    find "$WEB_DIR" -maxdepth 3 -type f \( -iname '*data*.js' -o -iname '*result*.json' -o -iname '*result*.js' -o -iname '*.csv' \) -printf '%p\n' | sort | head -120 || true
    echo "--- hardcoded keyword scan ---"
    grep -RIn --exclude-dir=node_modules --exclude='*.map' -E "all_results|staticResults|hardcode|localStorage|result_draws|manual_fetch|bbfs-final-dashboard" "$WEB_DIR" | head -120 || true
  else
    echo "Web dir not found: $WEB_DIR"
  fi
  echo

  echo "=== 9. DB TABLES RELATED TO BBFS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%bbfs%' OR table_name ILIKE '%prediction%' OR table_name ILIKE '%result%' OR table_name ILIKE '%score%' OR table_name ILIKE '%formula%') ORDER BY table_name;"
  echo

  echo "=== 10. BBFS RELATED TABLE COUNTS ==="
  sudo -u postgres psql -d bbfs_production <<'SQL'
DO $$
DECLARE r record;
DECLARE c bigint;
BEGIN
  FOR r IN SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%bbfs%' OR table_name ILIKE '%prediction%' OR table_name ILIKE '%result%' OR table_name ILIKE '%score%' OR table_name ILIKE '%formula%') ORDER BY table_name LOOP
    EXECUTE format('SELECT count(*) FROM %I', r.table_name) INTO c;
    RAISE NOTICE '% = % rows', r.table_name, c;
  END LOOP;
END $$;
SQL
  echo

  echo "=== 11. CONCLUSION CHECKLIST ==="
  echo "RESULT_DB_READ_CHECK: compare section 3 DB latest with section 4 API latest. If dates/results match, result API reads DB."
  echo "BBFS_DB_READ_CHECK: section 6 API output plus section 7 backend references show whether BBFS routes query DB tables."
  echo "FRONTEND_DYNAMIC_CHECK: section 8 shows whether frontend calls /api instead of static files."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_system_reads_database.txt"
