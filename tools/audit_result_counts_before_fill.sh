#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_result_counts_before_fill.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT JUMLAH RESULT SEBELUM LENGKAPI"
  echo "Generated: $STAMP"
  echo "Mode: READ ONLY - tidak mengubah database"
  echo
  echo "=== 1. RINGKASAN TOTAL RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_result,COUNT(DISTINCT market_id) AS market_punya_result,MIN(draw_date) AS tanggal_awal,MAX(draw_date) AS tanggal_akhir,COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d,COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d FROM result_draws;"
  echo
  echo "=== 2. RINGKASAN MARKET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_market,COUNT(*) FILTER (WHERE COALESCE(is_active,true)=true) AS active_market,COUNT(*) FILTER (WHERE COALESCE(is_active,true)=false) AS inactive_market FROM markets;"
  echo
  echo "=== 3. JUMLAH RESULT PER MARKET AKTIF - PALING SEDIKIT DI ATAS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir,(CURRENT_DATE - MAX(r.draw_date)) AS tertinggal_hari,COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') AS result_30_hari,COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '90 day') AS result_90_hari FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name ORDER BY COUNT(r.id) ASC, MAX(r.draw_date) ASC NULLS FIRST, LOWER(m.name) ASC;"
  echo
  echo "=== 4. MARKET AKTIF KURANG DARI 30 RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<30 ORDER BY COUNT(r.id) ASC,LOWER(m.name);"
  echo
  echo "=== 5. MARKET AKTIF TIDAK PUNYA RESULT TERBARU <= 2 HARI ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MAX(r.draw_date) AS latest_tanggal,(CURRENT_DATE - MAX(r.draw_date)) AS tertinggal_hari FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING MAX(r.draw_date)<CURRENT_DATE-INTERVAL '2 day' OR MAX(r.draw_date) IS NULL ORDER BY latest_tanggal NULLS FIRST,LOWER(m.name);"
  echo
  echo "=== 6. MARKET AKTIF RESULT 30 HARI KURANG DARI 10 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') AS result_30_hari,COUNT(r.id) AS total_result,MAX(r.draw_date) AS latest_tanggal FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id) FILTER (WHERE r.draw_date >= CURRENT_DATE-INTERVAL '30 day') < 10 ORDER BY result_30_hari ASC,total_result ASC,LOWER(m.name);"
  echo
  echo "=== 7. SOURCE ALIAS COVERAGE MARKET AKTIF ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(a.id) AS alias_count,STRING_AGG(a.source_market_name, ', ' ORDER BY a.source_market_name) AS aliases FROM markets m LEFT JOIN market_source_aliases a ON a.canonical_market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(a.id)=0 ORDER BY LOWER(m.name);"
  echo
  echo "=== 8. JUMLAH RESULT PER MARKET INACTIVE / HIDDEN ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=false GROUP BY m.id,m.code,m.name ORDER BY COUNT(r.id) ASC,LOWER(m.name) ASC;"
  echo
  echo "=== 9. INVALID 4D DETAIL SAMPLE - BELUM DIHAPUS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,r.draw_date,r.result,r.source,LEFT(COALESCE(r.raw_payload::text,''),180) AS raw_payload FROM result_draws r LEFT JOIN markets m ON m.id=r.market_id WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$' ORDER BY r.draw_date DESC NULLS LAST,r.id DESC LIMIT 100;"
  echo
  echo "=== 10. REKOMENDASI MESIN ==="
  echo "Jika bagian 4/5/6 kosong, market aktif tidak kurang secara jumlah dasar."
  echo "Jika ada baris di bagian 4/5/6, result harus dilengkapi dari source sebelum repair data invalid."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_result_counts_before_fill.txt"
