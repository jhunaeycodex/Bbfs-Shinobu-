#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/audit_migration_cloned_history.txt"
mkdir -p "$REPORT_DIR"

{
  echo "AUDIT CLONE MIGRASI HISTORY INACTIVE KE ACTIVE"
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Mode: READ ONLY - tidak hapus/tidak ubah data"
  echo

  echo "=== 1. DATABASE SUMMARY ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_markets, COUNT(*) FILTER (WHERE is_active) AS active_markets, COUNT(*) FILTER (WHERE NOT is_active) AS inactive_markets FROM markets;"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS total_results, COUNT(*) FILTER (WHERE result ~ '^[0-9]{4}$') AS valid_4d, COUNT(*) FILTER (WHERE result IS NULL OR result !~ '^[0-9]{4}$') AS invalid_4d FROM result_draws;"
  echo

  echo "=== 2. RESOLVED MIGRATION PAIRS DETECTED FROM SOURCE TAG ==="
  sudo -u postgres psql -d bbfs_production -c "WITH pairs AS (SELECT split_part(r.source,'merge_all_inactive_history:',2) AS pair_tag, COUNT(*) AS cloned_rows FROM result_draws r WHERE r.source LIKE '%merge_all_inactive_history:%' GROUP BY 1) SELECT pair_tag, split_part(pair_tag,'->',1) AS inactive_code, split_part(pair_tag,'->',2) AS active_code, cloned_rows FROM pairs ORDER BY cloned_rows DESC, pair_tag;"
  echo

  echo "=== 3. TOTAL CLONED ROWS BY SOURCE TAG ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS rows_with_merge_all_source FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%';"
  sudo -u postgres psql -d bbfs_production -c "SELECT COUNT(*) AS rows_with_any_merge_source FROM result_draws WHERE source LIKE '%merge_inactive_history:%' OR source LIKE '%merge_all_inactive_history:%';"
  echo

  echo "=== 4. INACTIVE VS ACTIVE SAME DATE+RESULT OVERLAP PER PAIR ==="
  sudo -u postgres psql -d bbfs_production -c "WITH pairs AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_all_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), resolved AS (SELECT p.old_code,p.new_code,oldm.id old_id,newm.id new_id,oldm.name old_name,newm.name new_name FROM pairs p JOIN markets oldm ON oldm.code=p.old_code JOIN markets newm ON newm.code=p.new_code), counts AS (SELECT r.old_code,r.new_code,r.old_name,r.new_name,(SELECT COUNT(*) FROM result_draws x WHERE x.market_id=r.old_id) old_rows,(SELECT COUNT(*) FROM result_draws x WHERE x.market_id=r.new_id) new_rows,(SELECT COUNT(*) FROM result_draws a JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result=a.result WHERE a.market_id=r.old_id) same_date_same_result,(SELECT COUNT(*) FROM result_draws a JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result<>a.result WHERE a.market_id=r.old_id) same_date_conflict_result FROM resolved r) SELECT *, ROUND((same_date_same_result::numeric / NULLIF(old_rows,0))*100,2) AS pct_old_cloned_to_active FROM counts ORDER BY same_date_same_result DESC, old_code;"
  echo

  echo "=== 5. TOTAL OVERLAP ROWS INACTIVE ↔ ACTIVE ==="
  sudo -u postgres psql -d bbfs_production -c "WITH pairs AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_all_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), resolved AS (SELECT p.old_code,p.new_code,oldm.id old_id,newm.id new_id FROM pairs p JOIN markets oldm ON oldm.code=p.old_code JOIN markets newm ON newm.code=p.new_code), overlap AS (SELECT r.old_code,r.new_code,COUNT(*) same_rows FROM resolved r JOIN result_draws a ON a.market_id=r.old_id JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result=a.result GROUP BY r.old_code,r.new_code) SELECT COUNT(*) AS pair_count, COALESCE(SUM(same_rows),0) AS total_same_date_same_result_overlap FROM overlap;"
  echo

  echo "=== 6. ACTIVE ROWS CREATED FROM MERGE SOURCE BY MARKET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(*) AS active_rows_created_by_merge,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.is_active=TRUE AND (r.source LIKE '%merge_all_inactive_history:%' OR r.source LIKE '%merge_inactive_history:%') GROUP BY m.code,m.name ORDER BY COUNT(*) DESC,m.code;"
  echo

  echo "=== 7. INACTIVE ROWS STILL PRESENT FOR MERGED OLD MARKETS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH old_codes AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_inactive_history:%') SELECT m.code,m.name,m.is_active,COUNT(r.id) AS rows_still_present,MIN(r.draw_date) AS min_date,MAX(r.draw_date) AS max_date FROM old_codes oc JOIN markets m ON m.code=oc.code LEFT JOIN result_draws r ON r.market_id=m.id GROUP BY m.code,m.name,m.is_active ORDER BY rows_still_present DESC,m.code;"
  echo

  echo "=== 8. IMPACT ON TOTAL COUNT IF OLD INACTIVE ARCHIVE EXCLUDED ==="
  sudo -u postgres psql -d bbfs_production -c "WITH old_codes AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), old_ids AS (SELECT m.id FROM markets m JOIN old_codes oc ON oc.code=m.code WHERE m.is_active=FALSE) SELECT (SELECT COUNT(*) FROM result_draws) AS total_physical_rows, (SELECT COUNT(*) FROM result_draws WHERE market_id NOT IN (SELECT id FROM old_ids)) AS total_excluding_merged_inactive_archives, (SELECT COUNT(*) FROM result_draws WHERE market_id IN (SELECT id FROM old_ids)) AS rows_in_merged_inactive_archives;"
  echo

  echo "=== 9. EXPORT DETAIL CSV ==="
  CSV1="$REPORT_DIR/migration_clone_pair_summary.csv"
  CSV2="$REPORT_DIR/migration_clone_overlap_detail_sample.csv"
  sudo -u postgres psql -d bbfs_production -c "COPY (WITH pairs AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_all_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), resolved AS (SELECT p.old_code,p.new_code,oldm.id old_id,newm.id new_id,oldm.name old_name,newm.name new_name FROM pairs p JOIN markets oldm ON oldm.code=p.old_code JOIN markets newm ON newm.code=p.new_code), counts AS (SELECT r.old_code,r.new_code,r.old_name,r.new_name,(SELECT COUNT(*) FROM result_draws x WHERE x.market_id=r.old_id) old_rows,(SELECT COUNT(*) FROM result_draws x WHERE x.market_id=r.new_id) new_rows,(SELECT COUNT(*) FROM result_draws a JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result=a.result WHERE a.market_id=r.old_id) same_date_same_result,(SELECT COUNT(*) FROM result_draws a JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result<>a.result WHERE a.market_id=r.old_id) same_date_conflict_result FROM resolved r) SELECT * FROM counts ORDER BY same_date_same_result DESC,old_code) TO '$CSV1' CSV HEADER;"
  sudo -u postgres psql -d bbfs_production -c "COPY (WITH pairs AS (SELECT DISTINCT split_part(split_part(source,'merge_all_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_all_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_all_inactive_history:%' UNION SELECT DISTINCT split_part(split_part(source,'merge_inactive_history:',2),'->',1) old_code, split_part(split_part(source,'merge_inactive_history:',2),'->',2) new_code FROM result_draws WHERE source LIKE '%merge_inactive_history:%'), resolved AS (SELECT p.old_code,p.new_code,oldm.id old_id,newm.id new_id FROM pairs p JOIN markets oldm ON oldm.code=p.old_code JOIN markets newm ON newm.code=p.new_code) SELECT r.old_code,r.new_code,a.draw_date,a.result AS old_result,b.result AS new_result,a.source AS old_source,b.source AS new_source,a.id old_id,b.id new_id FROM resolved r JOIN result_draws a ON a.market_id=r.old_id JOIN result_draws b ON b.market_id=r.new_id AND b.draw_date=a.draw_date AND b.result=a.result ORDER BY r.old_code,a.draw_date DESC LIMIT 10000) TO '$CSV2' CSV HEADER;"
  ls -lh "$CSV1" "$CSV2" || true
  echo

  echo "=== 10. KESIMPULAN ==="
  echo "NO_DELETE_DONE=true"
  echo "CLONE_MIGRATION_AUDIT=true"
  echo "INTERPRETATION: if old inactive archive rows remain, total physical result count includes both old archive and active migrated copy. Public/system counts should use active markets or exclude merged inactive archives."
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo "REPORT_PUSHED_TO_GITHUB=reports/audit_migration_cloned_history.txt"
