-- Data quality checks. Every check returns a count that must be 0.

-- 1. Duplicate business key in canonical (station_id, snapshot_ts)
SELECT 'dup_canonical' AS check_name, COUNT(*) AS bad_rows FROM (
  SELECT station_id, snapshot_ts FROM gbfs.station_status_canonical
  GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- 2. Duplicate grain in the fact (station_key, snapshot_ts)
SELECT 'dup_fact' AS check_name, COUNT(*) AS bad_rows FROM (
  SELECT station_key, snapshot_ts FROM gbfs.fact_station_status
  GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- 3. Duplicate station in dim_station
SELECT 'dup_dim_station' AS check_name, COUNT(*) AS bad_rows FROM (
  SELECT station_id FROM gbfs.dim_station GROUP BY 1 HAVING COUNT(*) > 1);

-- 4. Orphans: fact rows with no station
SELECT 'orphan_fact_station' AS check_name, COUNT(*) AS bad_rows
FROM gbfs.fact_station_status f
WHERE NOT EXISTS (SELECT 1 FROM gbfs.dim_station d WHERE d.station_key = f.station_key);

-- 5. Orphans: fact rows with no time row
SELECT 'orphan_fact_time' AS check_name, COUNT(*) AS bad_rows
FROM gbfs.fact_station_status f
WHERE NOT EXISTS (SELECT 1 FROM gbfs.dim_time t WHERE t.time_key = f.time_key);

-- 6. Canonical rows that never reached the fact
SELECT 'canonical_not_in_fact' AS check_name, COUNT(*) AS bad_rows
FROM gbfs.station_status_canonical c
WHERE NOT EXISTS (
  SELECT 1 FROM gbfs.fact_station_status f
  JOIN gbfs.dim_station d ON d.station_key = f.station_key
  WHERE d.station_id = c.station_id AND f.snapshot_ts = c.snapshot_ts);
