SELECT s.station_id, s.name, COUNT(*) AS snapshots,
       ROUND(AVG(f.num_bikes_available), 2) AS avg_bikes, MAX(f.num_bikes_available) AS max_bikes
FROM gbfs.fact_station_status f JOIN gbfs.dim_station s ON s.station_key = f.station_key
GROUP BY s.station_id, s.name ORDER BY avg_bikes DESC LIMIT 10;

SELECT s.station_id, s.name, f.snapshot_ts, f.num_bikes_available, f.num_ebikes_available, f.num_docks_available
FROM gbfs.fact_station_status f JOIN gbfs.dim_station s ON s.station_key = f.station_key
QUALIFY ROW_NUMBER() OVER (PARTITION BY f.station_key ORDER BY f.snapshot_ts DESC) = 1
ORDER BY s.name LIMIT 20;

SELECT station_id, snapshot_ts, COUNT(*) AS copies
FROM gbfs.station_status_canonical GROUP BY station_id, snapshot_ts HAVING COUNT(*) > 1;

SELECT station_id, snapshot_ts, COUNT(*) AS copies, COUNT(DISTINCT batch_id) AS batches
FROM gbfs.landing_station_status GROUP BY station_id, snapshot_ts HAVING COUNT(*) > 1
ORDER BY copies DESC LIMIT 10;

SELECT s.station_id, s.name, s.capacity, COUNT(*) AS snapshots,
       SUM(CASE WHEN f.num_bikes_available = 0 THEN 1 ELSE 0 END) AS empty_snapshots,
       ROUND(100.0 * SUM(CASE WHEN f.num_bikes_available = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_empty
FROM gbfs.fact_station_status f JOIN gbfs.dim_station s ON s.station_key = f.station_key
WHERE s.capacity > 0 AND f.is_renting = true
GROUP BY s.station_id, s.name, s.capacity HAVING COUNT(*) >= 20
ORDER BY pct_empty DESC, snapshots DESC LIMIT 10;

SELECT t.is_weekend, t.hour_of_day,
       ROUND(AVG(f.num_bikes_available), 1) AS avg_bikes,
       COUNT(*) AS snapshots
FROM gbfs.fact_station_status f
JOIN gbfs.dim_time t ON t.time_key = f.time_key
GROUP BY t.is_weekend, t.hour_of_day
ORDER BY t.is_weekend, t.hour_of_day;
