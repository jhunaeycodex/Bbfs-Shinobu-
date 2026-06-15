#!/usr/bin/env bash
set -euo pipefail
SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_all_markets_after_merge.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$REPORT_DIR"
{
  echo "AUDIT SEMUA PASARAN SETELAH MERGE HISTORY"
  echo "Generated: $STAMP"
  echo "Mode: READ ONLY - tidak mengubah database"
  echo
  echo "=== 1. RINGKASAN MARKET DAN RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_market,COUNT(*) FILTER (WHERE is_active=TRUE) AS active_market,COUNT(*) FILTER (WHERE COALESCE(is_active,FALSE)=FALSE) AS inactive_market FROM markets;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_result,COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d,COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d,MIN(draw_date) AS tanggal_awal,MAX(draw_date) AS tanggal_akhir FROM result_draws;"
  echo
  echo "=== 2. SEMUA MARKET AKTIF - URUT JUMLAH PALING KECIL ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name ORDER BY COUNT(r.id),LOWER(m.name);"
  echo
  echo "=== 3. MARKET AKTIF KURANG DARI 30 RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<30 ORDER BY COUNT(r.id),LOWER(m.name);"
  echo
  echo "=== 4. MARKET AKTIF KURANG DARI 1000 RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<1000 ORDER BY COUNT(r.id),LOWER(m.name);"
  echo
  echo "=== 5. MARKET AKTIF LATEST RESULT TERTINGGAL > 2 HARI ==="
  sudo -u postgres psql -d bbfs_production -c "WITH x AS (SELECT m.code,m.name,MAX(r.draw_date) AS latest_date,COUNT(r.id) AS total_result FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name) SELECT code,name,total_result,latest_date,(CURRENT_DATE-latest_date)::int AS hari_tertinggal FROM x WHERE latest_date IS NULL OR latest_date < CURRENT_DATE - INTERVAL '2 day' ORDER BY latest_date NULLS FIRST,name;"
  echo
  echo "=== 6. MARKET INACTIVE YANG MASIH PUNYA RESULT 1000+ ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,m.is_active,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,FALSE)=FALSE GROUP BY m.id,m.code,m.name,m.is_active HAVING COUNT(r.id)>=1000 ORDER BY COUNT(r.id) DESC,LOWER(m.name);"
  echo
  echo "=== 7. DUPLIKAT CODE / NAME MARKET AKTIF ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT code,COUNT(*) FROM markets WHERE is_active=TRUE GROUP BY code HAVING COUNT(*)>1 ORDER BY code;"
  sudo -u postgres psql -d bbfs_production -c "SELECT LOWER(name) AS normalized_name,COUNT(*) FROM markets WHERE is_active=TRUE GROUP BY LOWER(name) HAVING COUNT(*)>1 ORDER BY normalized_name;"
  echo
  echo "=== 8. INVALID RESULT 4D PER MARKET AKTIF ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS invalid_4d FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE AND (r.result IS NULL OR r.result !~ '^[0-9]{4}$') GROUP BY m.code,m.name ORDER BY invalid_4d DESC,m.name;"
  echo
  echo "=== 9. SEMUA MARKET INACTIVE PUNYA RESULT - URUT TERBESAR ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,m.is_active,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,FALSE)=FALSE GROUP BY m.id,m.code,m.name,m.is_active HAVING COUNT(r.id)>0 ORDER BY COUNT(r.id) DESC,LOWER(m.name);"
} > "$REPORT_FILE" 2>&1
cat "$REPORT_FILE"
bbfs-push-github || true
echo
echo "REPORT_PUSHED_TO_GITHUB=reports/audit_all_markets_after_merge.txt"
