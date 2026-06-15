#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
WEB="/var/www/jhunaey.my.id"
BACKEND="/opt/bbfs-shinobi/backend"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/full_website_audit.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$REPORT_DIR"

check_url(){
  local label="$1"
  local url="$2"
  local code
  code=$(curl -k -L -s -o /tmp/bbfs_audit_body.txt -w '%{http_code}' "$url" || echo '000')
  local bytes
  bytes=$(wc -c < /tmp/bbfs_audit_body.txt 2>/dev/null || echo 0)
  printf '%-34s %s bytes=%s %s\n' "$label" "$code" "$bytes" "$url"
}

{
  echo "BBFS FULL WEBSITE AUDIT"
  echo "Generated: $STAMP"
  echo
  echo "=== 1. SERVICE CHECK ==="
  echo "bbfs-backend: $(systemctl is-active bbfs-backend 2>/dev/null || true)"
  echo "nginx: $(systemctl is-active nginx 2>/dev/null || true)"
  nginx -t 2>&1 || true
  echo
  echo "=== 2. FILE EXISTENCE CHECK ==="
  for f in index.html bbfs-home-final.js bbfs-next-draw.html manual-fetch.html result-center.html auto-arsip.html data.js; do
    if [ -f "$WEB/$f" ]; then
      echo "OK   $WEB/$f"
    else
      echo "MISS $WEB/$f"
    fi
  done
  echo
  echo "=== 3. BACKEND SYNTAX CHECK ==="
  cd "$BACKEND"
  for f in server.js manual_fetch_routes.js market_alias.js scripts/manual_fetch_date_range_worker.js scripts/fetch_all_manual_job.js; do
    if [ -f "$f" ]; then
      echo "-- node --check $f"
      node --check "$f" 2>&1 || true
    else
      echo "MISS $BACKEND/$f"
    fi
  done
  echo
  echo "=== 4. FRONTEND JS SYNTAX CHECK ==="
  cd "$WEB"
  for f in bbfs-home-final.js data.js; do
    if [ -f "$f" ]; then
      echo "-- node --check $f"
      node --check "$f" 2>&1 || true
    fi
  done
  echo
  echo "=== 5. HTTP PAGE CHECK ==="
  check_url "home" "https://jhunaey.my.id/"
  check_url "bbfs-next-draw" "https://jhunaey.my.id/bbfs-next-draw.html"
  check_url "manual-fetch" "https://jhunaey.my.id/manual-fetch.html"
  check_url "result-center" "https://jhunaey.my.id/result-center.html"
  check_url "auto-arsip" "https://jhunaey.my.id/auto-arsip.html"
  echo
  echo "=== 6. API CHECK ==="
  check_url "api-markets" "http://127.0.0.1:3001/api/markets"
  check_url "api-results-latest" "http://127.0.0.1:3001/api/results/latest?market_code=taiwan"
  check_url "api-bbfs-dashboard" "http://127.0.0.1:3001/api/public/bbfs-final-dashboard?limit=5"
  check_url "api-manual-status" "http://127.0.0.1:3001/api/manual-fetch/date-range-status"
  echo
  echo "=== 7. API JSON PARSE CHECK ==="
  for url in \
    'http://127.0.0.1:3001/api/markets' \
    'http://127.0.0.1:3001/api/public/bbfs-final-dashboard?limit=5' \
    'http://127.0.0.1:3001/api/manual-fetch/date-range-status'; do
    echo "-- $url"
    curl -s "$url" | python3 -m json.tool >/dev/null && echo "JSON_OK" || echo "JSON_FAIL"
  done
  echo
  echo "=== 8. DATABASE SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS active_markets FROM markets WHERE COALESCE(is_active,true)=true;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS inactive_markets FROM markets WHERE COALESCE(is_active,true)=false;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS result_total FROM result_draws;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS invalid_result_4d FROM result_draws WHERE result !~ '^[0-9]{4}$';"
  echo
  echo "=== 9. ACTIVE MARKET LATEST RESULT BEHIND ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,MAX(r.draw_date) AS latest_tanggal FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING MAX(r.draw_date)<CURRENT_DATE-INTERVAL '2 day' OR MAX(r.draw_date) IS NULL ORDER BY latest_tanggal NULLS FIRST,LOWER(m.name) LIMIT 50;"
  echo
  echo "=== 10. BBFS ACTIVE STATUS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT user_status,prediction_status,can_show_prediction,COUNT(*) jumlah,ROUND(AVG(confidence)::numeric,2) avg_confidence,MIN(confidence) min_confidence,MAX(confidence) max_confidence FROM latest GROUP BY user_status,prediction_status,can_show_prediction ORDER BY user_status,prediction_status;"
  echo
  echo "=== 11. ACTIVE HOLD DETAIL ==="
  sudo -u postgres psql -d bbfs_production -c "WITH latest AS (SELECT DISTINCT ON (p.market_id) p.market_id,p.user_status,p.prediction_status,p.can_show_prediction,p.confidence,p.updated_at,p.gate_json FROM bbfs_final_next_draw_predictions p JOIN markets m ON m.id=p.market_id WHERE COALESCE(m.is_active,true)=true ORDER BY p.market_id,p.updated_at DESC) SELECT m.name,m.code,l.user_status,l.prediction_status,l.can_show_prediction,l.confidence,l.gate_json->'prediction_gate'->'errors' AS errors FROM latest l JOIN markets m ON m.id=l.market_id WHERE l.user_status='HOLD' ORDER BY l.confidence ASC;"
  echo
  echo "=== 12. DUPLICATE ACTIVE MARKET CODE/NAME ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT code,COUNT(*) FROM markets WHERE COALESCE(is_active,true)=true GROUP BY code HAVING COUNT(*)>1 ORDER BY COUNT(*) DESC,code;"
  sudo -u postgres psql -d bbfs_production -c "SELECT LOWER(name) AS name_key,COUNT(*) FROM markets WHERE COALESCE(is_active,true)=true GROUP BY LOWER(name) HAVING COUNT(*)>1 ORDER BY COUNT(*) DESC,name_key;"
  echo
  echo "=== 13. SOURCE ALIAS COVERAGE ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(DISTINCT m.id) AS active_markets,COUNT(DISTINCT a.canonical_market_id) AS active_with_alias FROM markets m LEFT JOIN market_source_aliases a ON a.canonical_market_id=m.id WHERE COALESCE(m.is_active,true)=true;"
  echo
  echo "=== 14. TODO/FIXME SEARCH ==="
  grep -RIn --exclude-dir=node_modules --exclude='*.bak' --exclude='*.backup*' --exclude='*.prepatch*' -E 'TODO|FIXME|console\.error|throw new Error|alert\(' "$WEB" "$BACKEND" | head -100 || true
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/full_website_audit.txt"
