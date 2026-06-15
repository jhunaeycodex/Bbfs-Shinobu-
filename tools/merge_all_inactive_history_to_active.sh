#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/merge_all_inactive_history_to_active.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
BACKUP_TABLE="result_draws_merge_all_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_CSV="$REPORT_DIR/${BACKUP_TABLE}.csv"
mkdir -p "$REPORT_DIR"
chmod 777 "$REPORT_DIR" || true

SQL_CANDIDATE="WITH inactive AS (SELECT m.id old_id,m.code old_code,m.name old_name,COUNT(r.id) total_old FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,FALSE)=FALSE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)>=1000), cand AS (SELECT *, CASE WHEN old_code='sgp-singapore' THEN 'singapore' WHEN old_code='chinapools' THEN 'china' WHEN old_code='magnum-cambodia' THEN 'cambodia' WHEN old_code='hongkong-lotto' THEN 'hongkong' WHEN old_code='sydney-lotto' THEN 'sydney' WHEN old_code LIKE 'toto-macau-%' THEN replace(old_code,'toto-macau-','totomacau-') WHEN old_code LIKE 'new-york-%' THEN replace(old_code,'new-york-','newyork-') WHEN old_code LIKE 'new-jersey-%' THEN replace(old_code,'new-jersey-','newjersey-') WHEN old_code LIKE 'north-carolina-%' THEN replace(old_code,'north-carolina-','carolina-') WHEN old_code LIKE 'washington-dc-%' THEN replace(old_code,'washington-dc-','washington-') ELSE old_code END AS step1_code FROM inactive), cand2 AS (SELECT *, replace(replace(replace(step1_code,'-evening','-eve'),'-midday','-mid'),'-morning','-mor') AS candidate_active_code FROM cand), resolved AS (SELECT c.*, m.id new_id,m.code new_code,m.name new_name FROM cand2 c JOIN markets m ON m.code=c.candidate_active_code AND m.is_active=TRUE)"

{
  echo "MERGE ALL INACTIVE HISTORY TO ACTIVE"
  echo "Generated: $STAMP"
  echo "Backup table: $BACKUP_TABLE"
  echo "Backup CSV: $BACKUP_CSV"
  echo "Mode: insert missing only, no delete inactive, no overwrite active result"
  echo
  echo "=== BEFORE ACTIVE <1000 WITH CANDIDATE ==="
  sudo -u postgres psql -d bbfs_production -c "WITH active_counts AS (SELECT m.id,m.code,m.name,COUNT(r.id) active_total,MIN(r.draw_date) active_awal,MAX(r.draw_date) active_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<1000), inactive AS (SELECT m.id old_id,m.code old_code,m.name old_name,COUNT(r.id) old_total,MIN(r.draw_date) old_awal,MAX(r.draw_date) old_akhir FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,FALSE)=FALSE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)>=1000), cand AS (SELECT *, CASE WHEN old_code='sgp-singapore' THEN 'singapore' WHEN old_code='chinapools' THEN 'china' WHEN old_code='magnum-cambodia' THEN 'cambodia' WHEN old_code='hongkong-lotto' THEN 'hongkong' WHEN old_code='sydney-lotto' THEN 'sydney' WHEN old_code LIKE 'toto-macau-%' THEN replace(old_code,'toto-macau-','totomacau-') WHEN old_code LIKE 'new-york-%' THEN replace(old_code,'new-york-','newyork-') WHEN old_code LIKE 'new-jersey-%' THEN replace(old_code,'new-jersey-','newjersey-') WHEN old_code LIKE 'north-carolina-%' THEN replace(old_code,'north-carolina-','carolina-') WHEN old_code LIKE 'washington-dc-%' THEN replace(old_code,'washington-dc-','washington-') ELSE old_code END AS step1_code FROM inactive), cand2 AS (SELECT *, replace(replace(replace(step1_code,'-evening','-eve'),'-midday','-mid'),'-morning','-mor') AS candidate_active_code FROM cand) SELECT a.code active_code,a.name active_name,a.active_total,a.active_awal,a.active_akhir,c.old_code,c.old_name,c.old_total,c.old_awal,c.old_akhir FROM active_counts a JOIN cand2 c ON c.candidate_active_code=a.code ORDER BY a.active_total,a.code;"
  echo
  echo "=== INSERT/OVERLAP SUMMARY BEFORE ==="
  sudo -u postgres psql -d bbfs_production -c "$SQL_CANDIDATE SELECT old_code,new_code,total_old,COUNT(o.id) FILTER (WHERE n.id IS NULL) AS missing_to_insert,COUNT(o.id) FILTER (WHERE n.id IS NOT NULL AND n.result=o.result) AS overlap_same,COUNT(o.id) FILTER (WHERE n.id IS NOT NULL AND n.result IS DISTINCT FROM o.result) AS overlap_diff FROM resolved x JOIN result_draws o ON o.market_id=x.old_id AND o.result ~ '^[0-9]{4}$' LEFT JOIN result_draws n ON n.market_id=x.new_id AND n.draw_date=o.draw_date GROUP BY old_code,new_code,total_old ORDER BY missing_to_insert DESC,old_code;"
  echo
  echo "=== CREATE BACKUP TABLE ==="
  sudo -u postgres psql -d bbfs_production -v ON_ERROR_STOP=1 -c "$SQL_CANDIDATE CREATE TABLE \"$BACKUP_TABLE\" AS SELECT r.*,m.code AS market_code,m.name AS market_name,m.is_active AS market_is_active,now() AS backed_up_at FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.id IN (SELECT old_id FROM resolved UNION SELECT new_id FROM resolved);"
  echo
  echo "=== WRITE BACKUP CSV ==="
  sudo -u postgres psql -d bbfs_production -c "\\copy (SELECT * FROM \"$BACKUP_TABLE\") TO '$BACKUP_CSV' CSV HEADER"
  ls -lh "$BACKUP_CSV"
  echo
  echo "=== INSERT MISSING HISTORY ==="
  sudo -u postgres psql -d bbfs_production -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
WITH inactive AS (
  SELECT m.id old_id,m.code old_code,m.name old_name,COUNT(r.id) total_old
  FROM markets m JOIN result_draws r ON r.market_id=m.id
  WHERE COALESCE(m.is_active,FALSE)=FALSE
  GROUP BY m.id,m.code,m.name
  HAVING COUNT(r.id)>=1000
), cand AS (
  SELECT *, CASE
    WHEN old_code='sgp-singapore' THEN 'singapore'
    WHEN old_code='chinapools' THEN 'china'
    WHEN old_code='magnum-cambodia' THEN 'cambodia'
    WHEN old_code='hongkong-lotto' THEN 'hongkong'
    WHEN old_code='sydney-lotto' THEN 'sydney'
    WHEN old_code LIKE 'toto-macau-%' THEN replace(old_code,'toto-macau-','totomacau-')
    WHEN old_code LIKE 'new-york-%' THEN replace(old_code,'new-york-','newyork-')
    WHEN old_code LIKE 'new-jersey-%' THEN replace(old_code,'new-jersey-','newjersey-')
    WHEN old_code LIKE 'north-carolina-%' THEN replace(old_code,'north-carolina-','carolina-')
    WHEN old_code LIKE 'washington-dc-%' THEN replace(old_code,'washington-dc-','washington-')
    ELSE old_code END AS step1_code
  FROM inactive
), cand2 AS (
  SELECT *, replace(replace(replace(step1_code,'-evening','-eve'),'-midday','-mid'),'-morning','-mor') AS candidate_active_code FROM cand
), resolved AS (
  SELECT c.*, m.id new_id,m.code new_code,m.name new_name
  FROM cand2 c JOIN markets m ON m.code=c.candidate_active_code AND m.is_active=TRUE
)
INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
SELECT x.new_id, o.draw_date, o.result,
       COALESCE(o.source,'') || '|merge_all_inactive_history:' || x.old_code || '->' || x.new_code,
       COALESCE(o.raw_payload,'{}'::jsonb) || jsonb_build_object(
         'merged_from_market_id', x.old_id,
         'merged_from_market_code', x.old_code,
         'merged_from_market_name', x.old_name,
         'merged_to_market_id', x.new_id,
         'merged_to_market_code', x.new_code,
         'merged_to_market_name', x.new_name,
         'merged_at', now()
       )
FROM resolved x
JOIN result_draws o ON o.market_id=x.old_id
WHERE o.result ~ '^[0-9]{4}$'
  AND NOT EXISTS (SELECT 1 FROM result_draws n WHERE n.market_id=x.new_id AND n.draw_date=o.draw_date);
COMMIT;
SQL
  echo
  echo "=== LOG OVERLAP DIFFERENT RESULTS TO CONFLICT TABLE ==="
  sudo -u postgres psql -d bbfs_production -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO market_source_alias_conflicts (
  source_name, source_value, source_code, canonical_market_id, canonical_market_code,
  canonical_market_name, source_url, draw_date, existing_result, incoming_result,
  existing_source, incoming_source, existing_market_id, incoming_market_id, notes
)
WITH inactive AS (
  SELECT m.id old_id,m.code old_code,m.name old_name,COUNT(r.id) total_old
  FROM markets m JOIN result_draws r ON r.market_id=m.id
  WHERE COALESCE(m.is_active,FALSE)=FALSE
  GROUP BY m.id,m.code,m.name
  HAVING COUNT(r.id)>=1000
), cand AS (
  SELECT *, CASE
    WHEN old_code='sgp-singapore' THEN 'singapore'
    WHEN old_code='chinapools' THEN 'china'
    WHEN old_code='magnum-cambodia' THEN 'cambodia'
    WHEN old_code='hongkong-lotto' THEN 'hongkong'
    WHEN old_code='sydney-lotto' THEN 'sydney'
    WHEN old_code LIKE 'toto-macau-%' THEN replace(old_code,'toto-macau-','totomacau-')
    WHEN old_code LIKE 'new-york-%' THEN replace(old_code,'new-york-','newyork-')
    WHEN old_code LIKE 'new-jersey-%' THEN replace(old_code,'new-jersey-','newjersey-')
    WHEN old_code LIKE 'north-carolina-%' THEN replace(old_code,'north-carolina-','carolina-')
    WHEN old_code LIKE 'washington-dc-%' THEN replace(old_code,'washington-dc-','washington-')
    ELSE old_code END AS step1_code
  FROM inactive
), cand2 AS (
  SELECT *, replace(replace(replace(step1_code,'-evening','-eve'),'-midday','-mid'),'-morning','-mor') AS candidate_active_code FROM cand
), resolved AS (
  SELECT c.*, m.id new_id,m.code new_code,m.name new_name
  FROM cand2 c JOIN markets m ON m.code=c.candidate_active_code AND m.is_active=TRUE
), diff AS (
  SELECT x.old_name,x.old_code,x.new_id,x.new_code,x.new_name,o.draw_date,n.result existing_result,o.result incoming_result,n.source existing_source,o.source incoming_source,n.market_id existing_market_id,o.market_id incoming_market_id
  FROM resolved x
  JOIN result_draws o ON o.market_id=x.old_id AND o.result ~ '^[0-9]{4}$'
  JOIN result_draws n ON n.market_id=x.new_id AND n.draw_date=o.draw_date
  WHERE n.result IS DISTINCT FROM o.result
)
SELECT old_name, old_code, old_code, new_id, new_code, new_name,
       'merge_all_inactive_history_to_active', draw_date, existing_result, incoming_result,
       existing_source, incoming_source, existing_market_id, incoming_market_id,
       'merge_all_overlap_diff: active result kept; inactive historical result logged only'
FROM diff d
WHERE NOT EXISTS (
  SELECT 1 FROM market_source_alias_conflicts c
  WHERE c.source_url='merge_all_inactive_history_to_active'
    AND c.source_code=d.old_code
    AND c.canonical_market_code=d.new_code
    AND c.draw_date=d.draw_date
    AND c.incoming_result=d.incoming_result
    AND c.existing_result=d.existing_result
);
SQL
  echo
  echo "=== ANALYZE ==="
  sudo -u postgres psql -d bbfs_production -c "ANALYZE result_draws;"
  echo
  echo "=== AFTER ACTIVE COUNTS FOR MERGED CANDIDATES ==="
  sudo -u postgres psql -d bbfs_production -c "$SQL_CANDIDATE SELECT new_code,new_name,COUNT(r.id) AS active_total,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM resolved x LEFT JOIN result_draws r ON r.market_id=x.new_id GROUP BY new_code,new_name ORDER BY active_total,new_code;"
  echo
  echo "=== AFTER ACTIVE <1000 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<1000 ORDER BY COUNT(r.id),LOWER(m.name);"
  echo
  echo "=== AFTER ACTIVE LATEST BEHIND >2 DAYS ==="
  sudo -u postgres psql -d bbfs_production -c "WITH x AS (SELECT m.code,m.name,MAX(r.draw_date) latest_date,COUNT(r.id) total_result FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.is_active=TRUE GROUP BY m.id,m.code,m.name) SELECT code,name,total_result,latest_date,(CURRENT_DATE-latest_date)::int AS hari_tertinggal FROM x WHERE latest_date IS NULL OR latest_date < CURRENT_DATE - INTERVAL '2 day' ORDER BY latest_date NULLS FIRST,name;"
  echo
  echo "=== INACTIVE 1000+ NO ACTIVE MATCH ==="
  sudo -u postgres psql -d bbfs_production -c "WITH inactive AS (SELECT m.id old_id,m.code old_code,m.name old_name,COUNT(r.id) total_old,MIN(r.draw_date) old_awal,MAX(r.draw_date) old_akhir FROM markets m JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,FALSE)=FALSE GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)>=1000), cand AS (SELECT *, CASE WHEN old_code='sgp-singapore' THEN 'singapore' WHEN old_code='chinapools' THEN 'china' WHEN old_code='magnum-cambodia' THEN 'cambodia' WHEN old_code='hongkong-lotto' THEN 'hongkong' WHEN old_code='sydney-lotto' THEN 'sydney' WHEN old_code LIKE 'toto-macau-%' THEN replace(old_code,'toto-macau-','totomacau-') WHEN old_code LIKE 'new-york-%' THEN replace(old_code,'new-york-','newyork-') WHEN old_code LIKE 'new-jersey-%' THEN replace(old_code,'new-jersey-','newjersey-') WHEN old_code LIKE 'north-carolina-%' THEN replace(old_code,'north-carolina-','carolina-') WHEN old_code LIKE 'washington-dc-%' THEN replace(old_code,'washington-dc-','washington-') ELSE old_code END AS step1_code FROM inactive), cand2 AS (SELECT *, replace(replace(replace(step1_code,'-evening','-eve'),'-midday','-mid'),'-morning','-mor') AS candidate_active_code FROM cand) SELECT c.old_code,c.old_name,c.total_old,c.old_awal,c.old_akhir,c.candidate_active_code FROM cand2 c LEFT JOIN markets m ON m.code=c.candidate_active_code AND m.is_active=TRUE WHERE m.id IS NULL ORDER BY c.total_old DESC,c.old_code;"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"
bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/merge_all_inactive_history_to_active.txt"
