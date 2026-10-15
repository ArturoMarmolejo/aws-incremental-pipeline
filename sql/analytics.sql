-- Q1. Which stations are most often empty (no classic bikes)? Most frequent first.
SELECT d.station_id, d.name,
       COUNT(*) AS snapshots,
       SUM(CASE WHEN f.num_bikes_available = 0 THEN 1 ELSE 0 END) AS empty_snapshots,
       ROUND(100.0 * SUM(CASE WHEN f.num_bikes_available = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_empty
FROM gbfs.fact_station_status f
JOIN gbfs.dim_station d ON d.station_key = f.station_key
GROUP BY d.station_id, d.name
HAVING COUNT(*) >= 10
ORDER BY pct_empty DESC, snapshots DESC
LIMIT 10;

-- Q2. Average bikes and docks available by hour of day
SELECT t.hour_of_day,
       ROUND(AVG(f.num_bikes_available), 2) AS avg_bikes,
       ROUND(AVG(f.num_docks_available), 2) AS avg_docks,
       COUNT(*) AS snapshots
FROM gbfs.fact_station_status f
JOIN gbfs.dim_time t ON t.time_key = f.time_key
GROUP BY t.hour_of_day
ORDER BY t.hour_of_day;

-- Q3. Stations with the highest e-bike share of available bikes
SELECT d.station_id, d.name, d.capacity,
       ROUND(AVG(f.num_ebikes_available), 2) AS avg_ebikes,
       ROUND(AVG(f.num_bikes_available), 2) AS avg_bikes,
       ROUND(100.0 * SUM(f.num_ebikes_available) / NULLIF(SUM(f.num_bikes_available), 0), 1) AS ebike_pct
FROM gbfs.fact_station_status f
JOIN gbfs.dim_station d ON d.station_key = f.station_key
GROUP BY d.station_id, d.name, d.capacity
HAVING SUM(f.num_bikes_available) > 0
ORDER BY ebike_pct DESC
LIMIT 10;

-- Q4. Stations that are full (no docks) most often
SELECT d.station_id, d.name,
       ROUND(100.0 * SUM(CASE WHEN f.num_docks_available = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_full
FROM gbfs.fact_station_status f
JOIN gbfs.dim_station d ON d.station_key = f.station_key
GROUP BY d.station_id, d.name
HAVING COUNT(*) >= 10
ORDER BY pct_full DESC
LIMIT 10;
