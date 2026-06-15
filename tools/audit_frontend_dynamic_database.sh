#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_frontend_dynamic_database.txt"
WEB_DIR="/var/www/jhunaey.my.id"
BASE_URL="https://jhunaey.my.id"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT FRONTEND DINAMIS MEMBACA API DATABASE"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY"
  echo

  echo "=== 1. FILE UTAMA WEBSITE ==="
  for f in index.html result-center.html auto-arsip.html data.js result-card-live.js; do
    if [ -f "$WEB_DIR/$f" ]; then
      echo "EXISTS|$f|$(stat -c '%s bytes|%y' "$WEB_DIR/$f")"
    else
      echo "MISSING|$f"
    fi
  done
  echo

  echo "=== 2. SCRIPT TAG DI INDEX ==="
  if [ -f "$WEB_DIR/index.html" ]; then
    grep -n "<script" "$WEB_DIR/index.html" || true
  fi
  echo

  echo "=== 3. CEK API CALL LITERAL DI FILE FRONTEND ==="
  echo "--- /api/ references ---"
  grep -RInF --exclude-dir=node_modules --exclude='*.map' "/api/" "$WEB_DIR" | head -160 || true
  echo
  echo "--- fetch( references ---"
  grep -RInF --exclude-dir=node_modules --exclude='*.map' "fetch(" "$WEB_DIR" | head -160 || true
  echo
  echo "--- XMLHttpRequest references ---"
  grep -RInF --exclude-dir=node_modules --exclude='*.map' "XMLHttpRequest" "$WEB_DIR" | head -80 || true
  echo

  echo "=== 4. CEK STATIC / HARDCODE RESULT DI FRONTEND ==="
  echo "--- files data/result/json/csv/js ---"
  find "$WEB_DIR" -maxdepth 3 -type f \( -iname '*data*.js' -o -iname '*result*.json' -o -iname '*result*.js' -o -iname '*.csv' \) -printf '%p|%s bytes|%TY-%Tm-%Td %TH:%TM\n' | sort || true
  echo
  echo "--- hardcode keywords ---"
  for kw in "all_results" "staticResults" "hardcode" "window.__" "const results" "let results" "resultData" "marketResults" "manualResults" "localStorage"; do
    echo "KEYWORD=$kw"
    grep -RInF --exclude-dir=node_modules --exclude='*.map' "$kw" "$WEB_DIR" | head -60 || true
  done
  echo

  echo "=== 5. RINGKASAN FILE DATA.JS ==="
  if [ -f "$WEB_DIR/data.js" ]; then
    echo "data.js_size=$(stat -c '%s' "$WEB_DIR/data.js")"
    echo "data.js_first_60_lines:"
    sed -n '1,60p' "$WEB_DIR/data.js"
    echo
    echo "data.js_api_refs:"
    grep -nF "/api/" "$WEB_DIR/data.js" || true
    grep -nF "fetch(" "$WEB_DIR/data.js" || true
  else
    echo "data.js missing"
  fi
  echo

  echo "=== 6. RINGKASAN FILE RESULT-CARD-LIVE.JS ==="
  if [ -f "$WEB_DIR/result-card-live.js" ]; then
    echo "result-card-live.js_size=$(stat -c '%s' "$WEB_DIR/result-card-live.js")"
    echo "result-card-live.js_api_refs:"
    grep -nF "/api/" "$WEB_DIR/result-card-live.js" || true
    grep -nF "fetch(" "$WEB_DIR/result-card-live.js" || true
    echo "result-card-live.js_first_120_lines:"
    sed -n '1,120p' "$WEB_DIR/result-card-live.js"
  else
    echo "result-card-live.js missing"
  fi
  echo

  echo "=== 7. LIVE HTML RESPONSE REFERENCES ==="
  for url in "$BASE_URL/" "$BASE_URL/result-center.html" "$BASE_URL/auto-arsip.html"; do
    echo "URL=$url"
    curl -skL --max-time 20 "$url" -o /tmp/frontend_page.html || true
    echo "status_or_size=$(wc -c < /tmp/frontend_page.html 2>/dev/null || echo 0)"
    echo "script_refs:"
    grep -n "<script" /tmp/frontend_page.html | head -60 || true
    echo "api_refs_in_html:"
    grep -nF "/api/" /tmp/frontend_page.html | head -60 || true
    echo
  done

  echo "=== 8. KESIMPULAN OTOMATIS AWAL ==="
  api_count=$(grep -RIlF --exclude-dir=node_modules --exclude='*.map' "/api/" "$WEB_DIR" | wc -l || echo 0)
  fetch_count=$(grep -RIlF --exclude-dir=node_modules --exclude='*.map' "fetch(" "$WEB_DIR" | wc -l || echo 0)
  static_count=$(find "$WEB_DIR" -maxdepth 3 -type f \( -iname '*data*.js' -o -iname '*result*.json' -o -iname '*result*.js' -o -iname '*.csv' \) | wc -l || echo 0)
  echo "frontend_files_with_api_refs=$api_count"
  echo "frontend_files_with_fetch_refs=$fetch_count"
  echo "frontend_static_candidate_files=$static_count"
  echo "MANUAL_REVIEW_REQUIRED: jika halaman utama memakai /api/public/bbfs-final-dashboard dan /api/results/latest maka dinamis; jika data.js berisi data result statis maka harus dikunci/dihapus dari sumber data tampilan."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_frontend_dynamic_database.txt"
