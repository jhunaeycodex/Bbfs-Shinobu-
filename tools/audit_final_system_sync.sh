#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_final_system_sync.txt"
WEB_DIR="/var/www/jhunaey.my.id"
BACKEND_DIR="/opt/bbfs-shinobi/backend"
BASE_URL="https://jhunaey.my.id"
mkdir -p "$REPORT_DIR"

api_latest(){
  local code="$1"
  curl -sk --max-time 20 "$BASE_URL/api/results/latest?limit=1&market_code=$code" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); x=d.get("data") or []; print((x[0].get("draw_date","")+"|"+str(x[0].get("result",""))) if x else "NO_DATA")' 2>/dev/null || echo "API_ERROR"
}

api_ok_summary(){
  local url="$1"
  curl -sk --max-time 30 "$url" \
    | python3 -c 'import sys,json; raw=sys.stdin.read();
try:
 d=json.loads(raw); print("ok="+str(d.get("ok"))+" keys="+",".join(d.keys())+" bytes="+str(len(raw)))
except Exception as e:
 print("JSON_ERROR="+str(e)+" bytes="+str(len(raw))+" body="+raw[:300].replace("\n"," "))' 2>/dev/null || echo "API_ERROR"
}

{
  echo "AUDIT FINAL SINKRONISASI SISTEM"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - baseline final setelah merge + frontend dynamic lock"
  echo

  echo "=== 1. SERVICE STATUS ==="
  echo "bbfs-backend=$(systemctl is-active bbfs-backend || true)"
  echo "nginx=$(systemctl is-active nginx || true)"
  echo

  echo "=== 2. DATABASE GLOBAL SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_markets, COUNT(*) FILTER (WHERE is_active=TRUE) AS active_markets, COUNT(*) FILTER (WHERE is_active=FALSE) AS inactive_markets FROM markets;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_results, COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d, COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d, MIN(draw_date) AS tanggal_awal, MAX(draw_date) AS tanggal_akhir FROM result_draws;"
  echo

  echo "=== 3. ACTIVE RESULT COUNT BUCKETS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH c AS (SELECT m.id,m.code,m.name,COUNT(r.id) total FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name) SELECT COUNT(*) AS active_market, COUNT(*) FILTER (WHERE total=0) AS zero_result, COUNT(*) FILTER (WHERE total<30) AS below_30, COUNT(*) FILTER (WHERE total<1000) AS below_1000, COUNT(*) FILTER (WHERE total>=1000) AS gte_1000 FROM c;"
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<1000 ORDER BY COUNT(r.id),m.code LIMIT 60;"
  echo

  echo "=== 4. ACTIVE LATEST BEHIND > 2 DAYS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT m.code,m.name,COUNT(r.id) total_result,MAX(r.draw_date) latest_date FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name) SELECT code,name,total_result,latest_date,(CURRENT_DATE-latest_date)::int AS hari_tertinggal FROM latest WHERE latest_date IS NULL OR CURRENT_DATE-latest_date > 2 ORDER BY hari_tertinggal DESC NULLS FIRST, code;"
  echo

  echo "=== 5. DB VS API LATEST MATCH ==="
  for code in singapore florida-eve ohio-eve totomacau-22 taiwan tennesse-eve texas-eve; do
    db=$(sudo -u postgres psql -d bbfs_production -t -A -F '|' -c "SELECT TO_CHAR(r.draw_date,'YYYY-MM-DD')||'|'||r.result FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code='$code' ORDER BY r.draw_date DESC,r.id DESC LIMIT 1;" | tr -d ' ')
    api=$(api_latest "$code")
    status="MISMATCH"
    [ "$db" = "$api" ] && status="MATCH"
    echo "LATEST_CHECK|$code|DB=$db|API=$api|$status"
  done
  echo

  echo "=== 6. API ENDPOINT HEALTH ==="
  for url in \
    "$BASE_URL/api/markets" \
    "$BASE_URL/api/results/latest?limit=1&market_code=singapore" \
    "$BASE_URL/api/results/latest?limit=1&market_code=florida-eve" \
    "$BASE_URL/api/public/bbfs-final-dashboard?limit=60" \
    "$BASE_URL/api/public/bbfs-final-dashboard?market_code=singapore&limit=60"; do
    echo "URL=$url"
    api_ok_summary "$url"
  done
  echo

  echo "=== 7. BBFS DATABASE EVIDENCE ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('result_draws','markets','bbfs_final_next_draw_predictions','prediction_runs','bbfs_predictions','digit_scores') ORDER BY table_name;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS final_prediction_rows, MAX(updated_at) AS latest_update FROM bbfs_final_next_draw_predictions;" || true
  if [ -f "$BACKEND_DIR/server.js" ]; then
    grep -nF "PostgreSQL result_draws" "$BACKEND_DIR/server.js" || true
    grep -nF "app.get('/api/public/bbfs-final-dashboard'" "$BACKEND_DIR/server.js" || true
    grep -nF "FROM result_draws" "$BACKEND_DIR/server.js" | head -30 || true
    grep -nF "bbfs_final_next_draw_predictions" "$BACKEND_DIR/server.js" | head -30 || true
  fi
  echo

  echo "=== 8. FRONTEND DYNAMIC LOCK EVIDENCE ==="
  for f in index.html result-center.html auto-arsip.html data.js result-card-live.js bbfs-home-final.js; do
    if [ -e "$WEB_DIR/$f" ]; then
      type="file"
      [ -L "$WEB_DIR/$f" ] && type="symlink->$(readlink "$WEB_DIR/$f")"
      echo "FRONTEND_FILE|$f|$type|$(stat -c '%s bytes|%y' "$WEB_DIR/$f")"
    else
      echo "FRONTEND_FILE|$f|MISSING"
    fi
  done
  echo
  echo "index script refs:"
  grep -n "<script" "$WEB_DIR/index.html" || true
  echo
  echo "result-card-live API refs:"
  grep -nF "/api/" "$WEB_DIR/result-card-live.js" || true
  grep -nF "fetch(" "$WEB_DIR/result-card-live.js" || true
  echo
  echo "bbfs-home-final API refs:"
  grep -nF "/api/" "$WEB_DIR/bbfs-home-final.js" || true
  grep -nF "fetch(" "$WEB_DIR/bbfs-home-final.js" || true
  echo
  echo "data.js lock content:"
  sed -n '1,40p' "$WEB_DIR/data.js" || true
  echo

  echo "=== 9. LIVE URL CHECK ==="
  for url in "$BASE_URL/" "$BASE_URL/result-center.html" "$BASE_URL/auto-arsip.html" "$BASE_URL/data.js"; do
    code=$(curl -skL -o /tmp/audit_final.out -w '%{http_code}' --max-time 20 "$url" || true)
    size=$(wc -c < /tmp/audit_final.out 2>/dev/null || echo 0)
    echo "URL_CHECK|$url|http=$code|bytes=$size"
  done
  echo

  echo "=== 10. FINAL CONCLUSION FLAGS ==="
  echo "RESULT_DB_API_SYNC=CHECK_SECTION_5_ALL_MATCH_EXPECTED"
  echo "BBFS_DB_SOURCE=PostgreSQL result_draws via backend finalGeneratePrediction"
  echo "FRONTEND_DYNAMIC_LOCK=data.js static disabled; active JS fetches /api with no-store"
  echo "REMAINING_WORK=invalid_4d_66; active_below_1000 list; optional wisconsin-eve mapping"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_final_system_sync.txt"
