#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_duplicate_result_draws.txt"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT DUPLIKAT DATA RESULT"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - tidak hapus/tidak ubah data"
  echo

  echo "=== 1. DATABASE SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_results, COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d, COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d, MIN(draw_date) AS tanggal_awal, MAX(draw_date) AS tanggal_akhir FROM result_draws;"
  echo

  echo "=== 2. DUPLIKAT SAME MARKET + SAME DATE ==="
  sudo -u postgres psql -d bbfs_production -c "WITH g AS (SELECT market_id, draw_date, COUNT(*) AS cnt, COUNT(DISTINCT result) AS distinct_result FROM result_draws GROUP BY market_id, draw_date HAVING COUNT(*)>1) SELECT COUNT(*) AS duplicate_date_groups, COALESCE(SUM(cnt-1),0) AS extra_rows, COUNT(*) FILTER (WHERE distinct_result=1) AS exact_same_result_groups, COUNT(*) FILTER (WHERE distinct_result>1) AS conflict_result_groups FROM g;"
  echo

  echo "=== 3. DUPLIKAT EXACT SAME MARKET + DATE + RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "WITH g AS (SELECT market_id, draw_date, result, COUNT(*) AS cnt FROM result_draws GROUP BY market_id, draw_date, result HAVING COUNT(*)>1) SELECT COUNT(*) AS exact_duplicate_groups, COALESCE(SUM(cnt-1),0) AS exact_extra_rows FROM g;"
  echo

  echo "=== 4. CONFLICT SAME MARKET + DATE BUT DIFFERENT RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "WITH g AS (SELECT market_id, draw_date, COUNT(*) AS cnt, COUNT(DISTINCT result) AS distinct_result FROM result_draws GROUP BY market_id, draw_date HAVING COUNT(*)>1 AND COUNT(DISTINCT result)>1) SELECT COUNT(*) AS conflict_groups, COALESCE(SUM(cnt),0) AS conflict_rows FROM g;"
  echo

  echo "=== 5. DUPLIKAT BY ACTIVE / INACTIVE MARKET ==="
  sudo -u postgres psql -d bbfs_production -c "WITH g AS (SELECT m.is_active, r.market_id, r.draw_date, COUNT(*) AS cnt, COUNT(DISTINCT r.result) AS distinct_result FROM result_draws r JOIN markets m ON m.id=r.market_id GROUP BY m.is_active,r.market_id,r.draw_date HAVING COUNT(*)>1) SELECT CASE WHEN is_active THEN 'ACTIVE' ELSE 'INACTIVE' END AS market_status, COUNT(*) AS duplicate_date_groups, COALESCE(SUM(cnt-1),0) AS extra_rows, COUNT(*) FILTER (WHERE distinct_result=1) AS exact_groups, COUNT(*) FILTER (WHERE distinct_result>1) AS conflict_groups FROM g GROUP BY is_active ORDER BY is_active DESC;"
  echo

  echo "=== 6. TOP DUPLIKAT GROUPS SAME MARKET + DATE ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.is_active,m.code,m.name,r.draw_date,COUNT(*) AS rows_on_date,COUNT(DISTINCT r.result) AS distinct_result,STRING_AGG(DISTINCT r.result, ', ' ORDER BY r.result) AS results FROM result_draws r JOIN markets m ON m.id=r.market_id GROUP BY m.is_active,m.code,m.name,r.market_id,r.draw_date HAVING COUNT(*)>1 ORDER BY COUNT(*) DESC, COUNT(DISTINCT r.result) DESC, m.is_active DESC, m.code, r.draw_date DESC LIMIT 100;"
  echo

  echo "=== 7. TOP EXACT DUPLICATE GROUPS SAME MARKET + DATE + RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.is_active,m.code,m.name,r.draw_date,r.result,COUNT(*) AS duplicate_rows,MIN(r.created_at) AS first_created,MAX(r.created_at) AS last_created,STRING_AGG(DISTINCT COALESCE(r.source,''), ' | ' ORDER BY COALESCE(r.source,'')) AS sources FROM result_draws r JOIN markets m ON m.id=r.market_id GROUP BY m.is_active,m.code,m.name,r.market_id,r.draw_date,r.result HAVING COUNT(*)>1 ORDER BY COUNT(*) DESC,m.is_active DESC,m.code,r.draw_date DESC LIMIT 120;"
  echo

  echo "=== 8. CONFLICT DETAIL SAME MARKET + DATE DIFFERENT RESULT ==="
  sudo -u postgres psql -d bbfs_production -c "WITH conflict AS (SELECT market_id,draw_date FROM result_draws GROUP BY market_id,draw_date HAVING COUNT(*)>1 AND COUNT(DISTINCT result)>1) SELECT m.is_active,m.code,m.name,r.draw_date,r.result,r.source,r.created_at,r.updated_at,r.id FROM result_draws r JOIN conflict c ON c.market_id=r.market_id AND c.draw_date=r.draw_date JOIN markets m ON m.id=r.market_id ORDER BY m.is_active DESC,m.code,r.draw_date DESC,r.created_at LIMIT 200;"
  echo

  echo "=== 9. DUPLIKAT YANG AKAN AMAN DIBERSIHKAN NANTI ==="
  echo "Kriteria aman nanti: same market_id + same draw_date + same result, sisakan 1 row terbaru/terpilih."
  sudo -u postgres psql -d bbfs_production -c "WITH ranked AS (SELECT r.*,ROW_NUMBER() OVER(PARTITION BY market_id,draw_date,result ORDER BY updated_at DESC NULLS LAST,created_at DESC NULLS LAST,id DESC) rn FROM result_draws r), dup AS (SELECT * FROM ranked WHERE rn>1) SELECT COUNT(*) AS candidate_exact_duplicate_rows_to_remove_later FROM dup;"
  echo

  echo "=== 10. UNIQUE / INDEX CHECK ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='result_draws' ORDER BY indexname;"
  echo

  echo "=== 11. CSV EXPORT DUPLIKAT RINGKAS ==="
  CSV1="$REPORT_DIR/duplicate_result_draw_groups.csv"
  CSV2="$REPORT_DIR/duplicate_result_conflicts.csv"
  sudo -u postgres psql -d bbfs_production -c "COPY (SELECT m.is_active,m.code,m.name,r.draw_date,COUNT(*) AS rows_on_date,COUNT(DISTINCT r.result) AS distinct_result,STRING_AGG(DISTINCT r.result, ', ' ORDER BY r.result) AS results FROM result_draws r JOIN markets m ON m.id=r.market_id GROUP BY m.is_active,m.code,m.name,r.market_id,r.draw_date HAVING COUNT(*)>1 ORDER BY COUNT(*) DESC,COUNT(DISTINCT r.result) DESC,m.code,r.draw_date DESC) TO '$CSV1' CSV HEADER;"
  sudo -u postgres psql -d bbfs_production -c "COPY (WITH conflict AS (SELECT market_id,draw_date FROM result_draws GROUP BY market_id,draw_date HAVING COUNT(*)>1 AND COUNT(DISTINCT result)>1) SELECT m.is_active,m.code,m.name,r.draw_date,r.result,r.source,r.created_at,r.updated_at,r.id FROM result_draws r JOIN conflict c ON c.market_id=r.market_id AND c.draw_date=r.draw_date JOIN markets m ON m.id=r.market_id ORDER BY m.is_active DESC,m.code,r.draw_date DESC,r.created_at) TO '$CSV2' CSV HEADER;"
  ls -lh "$CSV1" "$CSV2" || true
  echo

  echo "=== 12. KESIMPULAN ==="
  echo "DUPLICATE_AUDIT_ONLY=true"
  echo "NO_DELETE_DONE=true"
  echo "NEXT_SAFE_STEP: review conflict groups first; only exact duplicates can be cleaned automatically after approval."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_duplicate_result_draws.txt"
