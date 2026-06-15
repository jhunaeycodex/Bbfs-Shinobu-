#!/usr/bin/env bash
set -euo pipefail

SYNC_DIR="/opt/bbfs-github-sync"
REPORT_DIR="$SYNC_DIR/reports"
REPORT_FILE="$REPORT_DIR/merge_inactive_history_to_active_results.txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
BACKUP_TABLE="result_draws_merge_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_CSV="$REPORT_DIR/${BACKUP_TABLE}.csv"
mkdir -p "$REPORT_DIR"

{
  echo "MERGE INACTIVE HISTORY TO ACTIVE RESULTS"
  echo "Generated: $STAMP"
  echo "Backup table: $BACKUP_TABLE"
  echo "Backup CSV: $BACKUP_CSV"
  echo "Mode: insert missing historical rows to active markets; do not delete inactive rows"
  echo
  echo "=== TARGET MAPPING ==="
  echo "tennesse-evening  -> tennesse-eve"
  echo "tennesse-midday   -> tennesse-mid"
  echo "tennesse-morning  -> tennesse-mor"
  echo "texas-evening     -> texas-eve"
  echo "texas-morning     -> texas-mor"
  echo "sgp-singapore     -> singapore"
  echo
  echo "=== BEFORE COUNTS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,m.is_active,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.code IN ('tennesse-evening','tennesse-midday','tennesse-morning','texas-evening','texas-morning','sgp-singapore','tennesse-eve','tennesse-mid','tennesse-mor','texas-eve','texas-mor','singapore') GROUP BY m.id,m.code,m.name,m.is_active ORDER BY m.code;"
  echo
  echo "=== CREATE BACKUP TABLE + CSV ==="
  sudo -u postgres psql -d bbfs_production -v backup_table="$BACKUP_TABLE" -c "CREATE TABLE \"$BACKUP_TABLE\" AS SELECT r.*,m.code AS market_code,m.name AS market_name,m.is_active AS market_is_active,now() AS backed_up_at FROM result_draws r JOIN markets m ON m.id=r.market_id WHERE m.code IN ('tennesse-evening','tennesse-midday','tennesse-morning','texas-evening','texas-morning','sgp-singapore','tennesse-eve','tennesse-mid','tennesse-mor','texas-eve','texas-mor','singapore');"
  sudo -u postgres psql -d bbfs_production -c "\\copy (SELECT * FROM \"$BACKUP_TABLE\") TO '$BACKUP_CSV' CSV HEADER"
  ls -lh "$BACKUP_CSV"
  echo
  echo "=== OVERLAP / CONFLICT BEFORE MERGE ==="
  sudo -u postgres psql -d bbfs_production -c "WITH map(old_code,new_code) AS (VALUES ('tennesse-evening','tennesse-eve'),('tennesse-midday','tennesse-mid'),('tennesse-morning','tennesse-mor'),('texas-evening','texas-eve'),('texas-morning','texas-mor'),('sgp-singapore','singapore')), resolved AS (SELECT om.id old_id,nm.id new_id,om.code old_code,nm.code new_code FROM map JOIN markets om ON om.code=old_code JOIN markets nm ON nm.code=new_code) SELECT old_code,new_code,COUNT(*) FILTER (WHERE n.id IS NULL) AS missing_to_insert,COUNT(*) FILTER (WHERE n.id IS NOT NULL AND n.result=o.result) AS overlap_same,COUNT(*) FILTER (WHERE n.id IS NOT NULL AND n.result IS DISTINCT FROM o.result) AS overlap_diff FROM resolved x JOIN result_draws o ON o.market_id=x.old_id AND o.result ~ '^[0-9]{4}$' LEFT JOIN result_draws n ON n.market_id=x.new_id AND n.draw_date=o.draw_date GROUP BY old_code,new_code ORDER BY new_code;"
  echo
  echo "=== INSERT MISSING HISTORY ==="
  sudo -u postgres psql -d bbfs_production -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
WITH map(old_code,new_code) AS (
  VALUES
    ('tennesse-evening','tennesse-eve'),
    ('tennesse-midday','tennesse-mid'),
    ('tennesse-morning','tennesse-mor'),
    ('texas-evening','texas-eve'),
    ('texas-morning','texas-mor'),
    ('sgp-singapore','singapore')
), resolved AS (
  SELECT om.id AS old_id,nm.id AS new_id,om.code AS old_code,nm.code AS new_code,om.name AS old_name,nm.name AS new_name
  FROM map
  JOIN markets om ON om.code=old_code
  JOIN markets nm ON nm.code=new_code
)
INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
SELECT
  x.new_id,
  o.draw_date,
  o.result,
  COALESCE(o.source,'') || '|merge_inactive_history:' || x.old_code || '->' || x.new_code,
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
  AND NOT EXISTS (
    SELECT 1 FROM result_draws n
    WHERE n.market_id=x.new_id
      AND n.draw_date=o.draw_date
  );
COMMIT;
SQL
  echo
  echo "=== LOG OVERLAP DIFFERENT RESULTS TO CONFLICT TABLE ==="
  sudo -u postgres psql -d bbfs_production -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO market_source_alias_conflicts (
  source_name,
  source_value,
  source_code,
  canonical_market_id,
  canonical_market_code,
  canonical_market_name,
  source_url,
  draw_date,
  existing_result,
  incoming_result,
  existing_source,
  incoming_source,
  existing_market_id,
  incoming_market_id,
  notes
)
WITH map(old_code,new_code) AS (
  VALUES
    ('tennesse-evening','tennesse-eve'),
    ('tennesse-midday','tennesse-mid'),
    ('tennesse-morning','tennesse-mor'),
    ('texas-evening','texas-eve'),
    ('texas-morning','texas-mor'),
    ('sgp-singapore','singapore')
), resolved AS (
  SELECT om.id AS old_id,nm.id AS new_id,om.code AS old_code,nm.code AS new_code,om.name AS old_name,nm.name AS new_name
  FROM map
  JOIN markets om ON om.code=old_code
  JOIN markets nm ON nm.code=new_code
)
SELECT
  x.old_name,
  x.old_code,
  x.old_code,
  x.new_id,
  x.new_code,
  x.new_name,
  'merge_inactive_history_to_active_results',
  o.draw_date,
  n.result,
  o.result,
  n.source,
  o.source,
  n.market_id,
  o.market_id,
  'merge_history_overlap_diff: active result kept; inactive historical result logged only'
FROM resolved x
JOIN result_draws o ON o.market_id=x.old_id AND o.result ~ '^[0-9]{4}$'
JOIN result_draws n ON n.market_id=x.new_id AND n.draw_date=o.draw_date
WHERE n.result IS DISTINCT FROM o.result;
SQL
  echo
  echo "=== ANALYZE ==="
  sudo -u postgres psql -d bbfs_production -c "ANALYZE result_draws;"
  echo
  echo "=== AFTER COUNTS ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,m.is_active,COUNT(r.id) AS total_result,COUNT(r.id) FILTER (WHERE r.result ~ '^[0-9]{4}$') AS valid_4d,COUNT(r.id) FILTER (WHERE r.result IS NULL OR r.result !~ '^[0-9]{4}$') AS invalid_4d,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.code IN ('tennesse-eve','tennesse-mid','tennesse-mor','texas-eve','texas-mor','singapore','singapore-25') GROUP BY m.id,m.code,m.name,m.is_active ORDER BY m.code;"
  echo
  echo "=== ACTIVE MARKET < 1000 AFTER FOR TARGET ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE m.code IN ('tennesse-eve','tennesse-mid','tennesse-mor','texas-eve','texas-mor','singapore') GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<1000 ORDER BY COUNT(r.id);"
  echo
  echo "=== FINAL ACTIVE RESULT LESS THAN 30 ==="
  sudo -u postgres psql -d bbfs_production -c "SELECT m.code,m.name,COUNT(r.id) AS total_result,MIN(r.draw_date) AS tanggal_awal,MAX(r.draw_date) AS tanggal_akhir FROM markets m LEFT JOIN result_draws r ON r.market_id=m.id WHERE COALESCE(m.is_active,true)=true GROUP BY m.id,m.code,m.name HAVING COUNT(r.id)<30 ORDER BY COUNT(r.id),LOWER(m.name);"
} > "$REPORT_FILE" 2>&1

cat "$REPORT_FILE"

bbfs-push-github || true

echo

echo "REPORT_PUSHED_TO_GITHUB=reports/merge_inactive_history_to_active_results.txt"
