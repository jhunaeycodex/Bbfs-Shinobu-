#!/usr/bin/env bash
set -euo pipefail
SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_specific_1000_results.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
mkdir -p "$REPORT_DIR"
{
  echo "AUDIT MARKET YANG SEHARUSNYA 1000+ RESULT"
  echo "Generated: $STAMP"
  echo "Mode: READ ONLY - tidak mengubah database"
  echo
  echo "=== TARGET MARKET ==="
  echo "Tennesse Morning / Tennesse Mor"
  echo "Texas Evening / Texas Eve"
  echo "Texas Morning / Texas Mor"
  echo "Singapore"
  echo
  echo "=== 1. CARI SEMUA MARKET MIRIP TARGET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.id,m.code,m.name,m.is_active,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE LOWER(m.code) ~ '(tenn|texas|singapore)' OR LOWER(m.name) ~ '(tenn|texas|singapore)' GROUP BY m.id,m.code,m.name,m.is_active ORDER BY LOWER(m.name),m.is_active DESC,total_result DESC;"
  echo
  echo "=== 2. RESULT TARGET AKTIF SAAT INI ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.id,m.code,m.name,m.is_active,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.code IN ('tennesse-mor','texas-eve','texas-mor','singapore','singapore-25') GROUP BY m.id,m.code,m.name,m.is_active ORDER BY m.code;"
  echo
  echo "=== 3. CEK DUPLIKAT RESULT PER TANGGAL DI TARGET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,r.draw_date,COUNT(*) AS duplicate_count,STRING_AGG(r.result, ',' ORDER BY r.result) AS results FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code IN ('tennesse-mor','texas-eve','texas-mor','singapore','singapore-25') GROUP BY m.code,m.name,r.draw_date HAVING COUNT(*)>1 ORDER BY m.code,r.draw_date DESC LIMIT 100;"
  echo
  echo "=== 4. DISTRIBUSI BULANAN TARGET AKTIF ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,to_char(r.draw_date,'YYYY-MM') AS bulan,COUNT(*) AS jumlah FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code IN ('tennesse-mor','texas-eve','texas-mor','singapore','singapore-25') GROUP BY m.code,m.name,to_char(r.draw_date,'YYYY-MM') ORDER BY m.code,bulan;"
  echo
  echo "=== 5. CEK TABEL ALIAS - STRUKTUR KOLOM ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT column_name,data_type FROM information_schema.columns WHERE table_name='market_source_aliases' ORDER BY ordinal_position;"
  echo
  echo "=== 6. CEK ALIAS TARGET DARI market_source_aliases ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT a.* FROM market_source_aliases a LEFT JOIN markets m ON m.id=a.canonical_market_id WHERE LOWER(COALESCE(m.code,'')) ~ '(tenn|texas|singapore)' OR LOWER(COALESCE(m.name,'')) ~ '(tenn|texas|singapore)' OR LOWER(a::text) ~ '(tenn|texas|singapore)' ORDER BY a.id LIMIT 200;"
  echo
  echo "=== 7. CEK APA ADA RESULT LAMA DI MARKET INACTIVE MIRIP TARGET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.id,m.code,m.name,m.is_active,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,false)=false AND (LOWER(m.code) ~ '(tenn|texas|singapore)' OR LOWER(m.name) ~ '(tenn|texas|singapore)') GROUP BY m.id,m.code,m.name,m.is_active ORDER BY total_result DESC,LOWER(m.name);"
  echo
  echo "=== 8. CEK IMPORT BATCH TERKAIT TARGET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name ILIKE '%import%' ORDER BY table_name;"
  echo
  echo "=== 9. SOURCE ALIAS CONFLICT TERKAIT TARGET JIKA ADA ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name ILIKE '%alias%conflict%' ORDER BY table_name;"
  sudo -u postgres psql -d bbfs_production -c "SELECT * FROM market_source_alias_conflicts WHERE LOWER(COALESCE(source_market_name,'')) ~ '(tenn|texas|singapore)' OR LOWER(COALESCE(canonical_market_code,'')) ~ '(tenn|texas|singapore)' ORDER BY created_at DESC LIMIT 100;" 2>&1 || true
  echo
  echo "=== 10. KESIMPULAN DIBACA MANUAL ==="
  echo "Jika tidak ada market inactive dengan 1000+ result, berarti data historis 1000+ belum ada di DB saat ini dan harus diimport/fetch range lama."
  echo "Jika ada market inactive dengan 1000+ result, nanti perlu merge market_id ke market aktif, bukan fetch ulang."
} > "$REPORT_FILE" 2>&1
cat "$REPORT_FILE"
bbfs-push-github || true
echo
echo "REPORT_PUSHED_TO_GITHUB=reports/audit_specific_1000_results.txt"
