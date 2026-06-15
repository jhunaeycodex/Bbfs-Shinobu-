#!/usr/bin/env bash
set -euo pipefail
SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_system_reads_database_v2.txt"
BASE_URL="https://jhunaey.my.id"
BACKEND_DIR="/opt/bbfs-shinobi/backend"
WEB_DIR="/var/www/jhunaey.my.id"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT SISTEM MEMBACA DATABASE - V2 RINGKAS"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY"
  echo
  echo "=== SERVICE ==="
  echo "bbfs-backend=$(systemctl is-active bbfs-backend || true)"
  echo "nginx=$(systemctl is-active nginx || true)"
  echo
  echo "=== DB SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -t -A -F '|' -c "SELECT 'markets',COUNT(*),COUNT(*) FILTER (WHERE is_active=TRUE) FROM markets;"
  sudo -u postgres psql -d bbfs_production -t -A -F '|' -c "SELECT 'results',COUNT(*),COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$'),COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$'),MIN(draw_date),MAX(draw_date) FROM result_draws;"
  echo
  echo "=== DB_LATEST_BY_MARKET ==="
  for code in singapore florida-eve ohio-eve totomacau-22 taiwan; do
    sudo -u postgres psql -d bbfs_production -t -A -F '|' -c "SELECT 'DB','$code',r.draw_date,r.result FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code='$code' ORDER BY r.draw_date DESC,r.id DESC LIMIT 1;"
  done
  echo
  echo "=== API_LATEST_BY_MARKET ==="
  for code in singapore florida-eve ohio-eve totomacau-22 taiwan; do
    printf 'API|%s|' "$code"
    curl -sk --max-time 20 "$BASE_URL/api/results/latest?market_code=$code" | python3 -c "import sys,json; d=json.load(sys.stdin); x=d.get('data',[]); print((x[0].get('draw_date','')+'|'+x[0].get('result','')) if x else 'NO_DATA')" || echo "ERROR"
  done
  echo
  echo "=== RESULT_API_DB_MATCH_EXPECTATION ==="
  echo "Compare DB_LATEST_BY_MARKET with API_LATEST_BY_MARKET. Same date+result means result API reads DB."
  echo
  echo "=== BBFS_API_CHECK ==="
  for url in \
    "$BASE_URL/api/public/bbfs-final-dashboard?limit=5" \
    "$BASE_URL/api/public/bbfs-final-dashboard?market_code=singapore&limit=3"; do
    echo "URL=$url"
    curl -sk --max-time 20 "$url" | python3 -c "import sys,json; raw=sys.stdin.read(); print(raw[:1200].replace('\\n',' '));\ntry:\n d=json.loads(raw); print('JSON_OK keys='+','.join(d.keys()) if isinstance(d,dict) else 'JSON_OK list')\nexcept Exception as e: print('JSON_ERROR '+str(e))" || true
    echo
  done
  echo
  echo "=== BACKEND_DATABASE_REFERENCES ==="
  if [ -d "$BACKEND_DIR" ]; then
    echo "result_draws_refs=$(grep -RIl --exclude-dir=node_modules --exclude='*.log' 'result_draws' "$BACKEND_DIR" | wc -l)"
    grep -RIn --exclude-dir=node_modules --exclude='*.log' 'result_draws' "$BACKEND_DIR" | head -30 || true
    echo "bbfs_refs=$(grep -RIl --exclude-dir=node_modules --exclude='*.log' -E 'bbfs|prediction|final_predictions|bbfs_predictions|prediction_runs|digit_scores' "$BACKEND_DIR" | wc -l)"
    grep -RIn --exclude-dir=node_modules --exclude='*.log' -E 'bbfs-final-dashboard|bbfs|prediction|final_predictions|bbfs_predictions|prediction_runs|digit_scores|pool.query|db.query|DATABASE_URL' "$BACKEND_DIR" | head -80 || true
  else
    echo "BACKEND_DIR_NOT_FOUND=$BACKEND_DIR"
  fi
  echo
  echo "=== FRONTEND_API_REFERENCES ==="
  if [ -d "$WEB_DIR" ]; then
    echo "api_refs=$(grep -RIl --exclude-dir=node_modules --exclude='*.map' -E '/api/|fetch\\(|axios|XMLHttpRequest' "$WEB_DIR" | wc -l)"
    grep -RIn --exclude-dir=node_modules --exclude='*.map' -E '/api/|fetch\\(|axios|XMLHttpRequest' "$WEB_DIR" | head -80 || true
    echo "static_result_files="
    find "$WEB_DIR" -maxdepth 3 -type f \( -iname '*data*.js' -o -iname '*result*.json' -o -iname '*result*.js' -o -iname '*.csv' \) -printf '%p\n' | sort | head -80 || true
  else
    echo "WEB_DIR_NOT_FOUND=$WEB_DIR"
  fi
} > "$REPORT_FILE" 2>&1
cat "$REPORT_FILE"
bbfs-push-github || true
echo "REPORT_PUSHED_TO_GITHUB=reports/audit_system_reads_database_v2.txt"
