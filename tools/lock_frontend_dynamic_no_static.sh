#!/usr/bin/env bash
set -euo pipefail

WEB_DIR="/var/www/jhunaey.my.id"
SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$WEB_DIR/backups/frontend_dynamic_lock_$STAMP"
REPORT_FILE="$REPORT_DIR/lock_frontend_dynamic_no_static.txt"
mkdir -p "$REPORT_DIR" "$BACKUP_DIR"

{
  echo "LOCK FRONTEND DYNAMIC - NO STATIC RESULT SOURCE"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: WRITE - backup lalu nonaktifkan data.js static bila tidak dipakai aktif"
  echo "Web dir: $WEB_DIR"
  echo "Backup dir: $BACKUP_DIR"
  echo

  echo "=== 1. BACKUP FILE PENTING ==="
  for f in index.html data.js result-card-live.js bbfs-home-final.js menu-direct-links.js; do
    if [ -f "$WEB_DIR/$f" ]; then
      cp -a "$WEB_DIR/$f" "$BACKUP_DIR/$f"
      echo "BACKUP|$f|OK"
    else
      echo "BACKUP|$f|MISSING"
    fi
  done
  echo

  echo "=== 2. CEK REFERENSI AKTIF KE data.js ==="
  ACTIVE_REFS=$(grep -RInF --include='*.html' --include='*.js' --exclude='data.js' --exclude='*.bak' --exclude-dir='backups' --exclude-dir='backup' 'data.js' "$WEB_DIR" || true)
  if [ -n "$ACTIVE_REFS" ]; then
    echo "$ACTIVE_REFS"
    echo "ACTION: data.js TIDAK dinonaktifkan karena masih ada referensi aktif."
    DATA_ACTION="SKIPPED_ACTIVE_REFS_FOUND"
  else
    echo "Tidak ada referensi aktif ke data.js di HTML/JS utama."
    DATA_ACTION="DISABLE_DATA_JS"
  fi
  echo

  echo "=== 3. NONAKTIFKAN data.js STATIC JIKA AMAN ==="
  if [ "$DATA_ACTION" = "DISABLE_DATA_JS" ] && [ -f "$WEB_DIR/data.js" ]; then
    mv "$WEB_DIR/data.js" "$BACKUP_DIR/data.js.static_backup_$STAMP"
    cat > "$WEB_DIR/data.js" <<'JS'
// BBFS Shinobi static data disabled.
// Frontend locked to API/database source only.
// Do not place result/prediction arrays here.
window.BBFS_STATIC_DATA_DISABLED = true;
window.BBFS_DATA_SOURCE_LOCK = 'API_DATABASE_ONLY';
JS
    echo "data.js lama dipindah ke backup. data.js baru dibuat sebagai stub API_DATABASE_ONLY."
  elif [ ! -f "$WEB_DIR/data.js" ]; then
    echo "data.js tidak ada. Tidak ada tindakan."
  else
    echo "data.js tidak diubah karena masih ada referensi aktif."
  fi
  echo

  echo "=== 4. FILE FISIK UNTUK URL FALLBACK ==="
  for f in result-center.html auto-arsip.html; do
    if [ -e "$WEB_DIR/$f" ]; then
      echo "EXISTS|$f|tidak diubah"
    else
      ln -s index.html "$WEB_DIR/$f"
      echo "SYMLINK_CREATED|$f -> index.html"
    fi
  done
  echo

  echo "=== 5. BERSIHKAN BACKUP .bak DARI WEB ROOT LANGSUNG ==="
  # Pindahkan .bak di level root agar tidak terserve sebagai halaman lama. Backup tetap tersimpan.
  shopt -s nullglob
  moved=0
  for bak in "$WEB_DIR"/*.bak "$WEB_DIR"/*.backup* "$WEB_DIR"/*.before_*; do
    [ -e "$bak" ] || continue
    base="$(basename "$bak")"
    mv "$bak" "$BACKUP_DIR/$base"
    echo "MOVED_BACKUP_FILE|$base"
    moved=$((moved+1))
  done
  echo "backup_files_moved=$moved"
  echo

  echo "=== 6. VERIFIKASI SCRIPT TAG LIVE ==="
  grep -n "<script" "$WEB_DIR/index.html" || true
  echo

  echo "=== 7. VERIFIKASI API REFS LIVE JS ==="
  echo "result-card-live.js refs:"
  grep -nF "/api/" "$WEB_DIR/result-card-live.js" || true
  grep -nF "fetch(" "$WEB_DIR/result-card-live.js" || true
  echo
  echo "bbfs-home-final.js refs:"
  grep -nF "/api/" "$WEB_DIR/bbfs-home-final.js" || true
  grep -nF "fetch(" "$WEB_DIR/bbfs-home-final.js" || true
  echo

  echo "=== 8. VERIFIKASI STATIC CANDIDATES SETELAH LOCK ==="
  find "$WEB_DIR" -maxdepth 2 -type f \( -iname '*data*.js' -o -iname '*result*.json' -o -iname '*result*.js' -o -iname '*.csv' \) -printf '%p|%s bytes|%TY-%Tm-%Td %TH:%TM\n' | sort || true
  echo
  echo "data.js content:"
  sed -n '1,40p' "$WEB_DIR/data.js" || true
  echo

  echo "=== 9. LIVE URL CHECK ==="
  for url in "https://jhunaey.my.id/" "https://jhunaey.my.id/result-center.html" "https://jhunaey.my.id/auto-arsip.html" "https://jhunaey.my.id/data.js"; do
    code=$(curl -skL -o /tmp/lock_check.out -w '%{http_code}' --max-time 20 "$url" || true)
    size=$(wc -c < /tmp/lock_check.out 2>/dev/null || echo 0)
    echo "URL_CHECK|$url|http=$code|bytes=$size"
  done
  echo

  echo "=== 10. KESIMPULAN ==="
  echo "DATA_JS_ACTION=$DATA_ACTION"
  echo "FRONTEND_LOCK_EXPECTATION: index memakai result-card-live.js dan bbfs-home-final.js; kedua file memakai /api dan fetch no-store; data.js static dinonaktifkan jika tidak ada referensi aktif."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/lock_frontend_dynamic_no_static.txt"
