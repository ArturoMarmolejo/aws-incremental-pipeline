-- Canonical: one row per (station_id, snapshot_ts), whichever batch brought it first.
-- NOT EXISTS makes the statement idempotent: rows already present are skipped.
INSERT INTO gbfs.station_status_canonical (
    station_id, snapshot_ts, num_bikes_available, num_ebikes_available, num_docks_available,
    is_installed, is_renting, is_returning, last_reported_ts, first_batch_id
)
SELECT
    l.station_id, l.snapshot_ts, l.num_bikes_available, l.num_ebikes_available, l.num_docks_available,
    l.is_installed, l.is_renting, l.is_returning, l.last_reported_ts, l.batch_id
FROM gbfs.landing_station_status l
WHERE l.batch_id = '{{batch_id}}'
  AND NOT EXISTS (
      SELECT 1
      FROM gbfs.station_status_canonical c
      WHERE c.station_id = l.station_id
        AND c.snapshot_ts = l.snapshot_ts
  );


-- 1. Canonical: one row per (station_id, snapshot_ts); NOT EXISTS skips rows already present.
INSERT INTO gbfs.station_status_canonical (
    station_id, snapshot_ts, num_bikes_available, num_ebikes_available, num_docks_available,
    is_installed, is_renting, is_returning, last_reported_ts, first_batch_id
)
SELECT
    l.station_id, l.snapshot_ts, l.num_bikes_available, l.num_ebikes_available, l.num_docks_available,
    l.is_installed, l.is_renting, l.is_returning, l.last_reported_ts, l.batch_id
FROM gbfs.landing_station_status l
WHERE l.batch_id = '{{batch_id}}'
  AND NOT EXISTS (
      SELECT 1 FROM gbfs.station_status_canonical c
      WHERE c.station_id = l.station_id AND c.snapshot_ts = l.snapshot_ts
  );

-- 2. dim_time: add the hours this batch needs.
INSERT INTO gbfs.dim_time (time_key, hour_start, date_value, hour_of_day, day_of_week, is_weekend)
SELECT DISTINCT
    CAST(TO_CHAR(DATE_TRUNC('hour', c.snapshot_ts), 'YYYYMMDDHH24') AS INT),
    DATE_TRUNC('hour', c.snapshot_ts),
    CAST(DATE_TRUNC('hour', c.snapshot_ts) AS DATE),
    CAST(EXTRACT(hour FROM c.snapshot_ts) AS SMALLINT),
    CAST(EXTRACT(dow FROM c.snapshot_ts) AS SMALLINT),
    CASE WHEN EXTRACT(dow FROM c.snapshot_ts) IN (0, 6) THEN TRUE ELSE FALSE END
FROM gbfs.station_status_canonical c
WHERE c.first_batch_id = '{{batch_id}}'
  AND NOT EXISTS (
      SELECT 1 FROM gbfs.dim_time t
      WHERE t.time_key = CAST(TO_CHAR(DATE_TRUNC('hour', c.snapshot_ts), 'YYYYMMDDHH24') AS INT)
  );

-- 3a. dim_station, Type 1: overwrite attributes of stations we already know.
UPDATE gbfs.dim_station
SET name = s.name, short_name = s.short_name, lat = s.lat, lon = s.lon,
    capacity = s.capacity, updated_at = GETDATE()
FROM gbfs.landing_station_information s
WHERE s.batch_id = '{{batch_id}}'
  AND gbfs.dim_station.station_id = s.station_id;

-- 3b. dim_station: add stations we have not seen.
INSERT INTO gbfs.dim_station (station_id, name, short_name, lat, lon, capacity, first_seen_batch)
SELECT s.station_id, s.name, s.short_name, s.lat, s.lon, s.capacity, s.batch_id
FROM gbfs.landing_station_information s
WHERE s.batch_id = '{{batch_id}}'
  AND NOT EXISTS (SELECT 1 FROM gbfs.dim_station d WHERE d.station_id = s.station_id);

-- 4. Fact: this batch's new canonical rows, with the dimension keys looked up.
INSERT INTO gbfs.fact_station_status (
    station_key, time_key, snapshot_ts, num_bikes_available, num_ebikes_available,
    num_docks_available, is_renting, is_returning, first_batch_id
)
SELECT
    d.station_key,
    t.time_key,
    c.snapshot_ts,
    c.num_bikes_available, c.num_ebikes_available, c.num_docks_available,
    c.is_renting, c.is_returning, c.first_batch_id
FROM gbfs.station_status_canonical c
JOIN gbfs.dim_station d ON d.station_id = c.station_id
JOIN gbfs.dim_time t
  ON t.time_key = CAST(TO_CHAR(DATE_TRUNC('hour', c.snapshot_ts), 'YYYYMMDDHH24') AS INT)
WHERE c.first_batch_id = '{{batch_id}}'
  AND NOT EXISTS (
      SELECT 1 FROM gbfs.fact_station_status f
      WHERE f.station_key = d.station_key AND f.snapshot_ts = c.snapshot_ts
  );
