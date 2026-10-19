SELECT station_id,
       COUNT(*)                                      AS snapshots,
       MAX(num_bikes_available)                      AS max_bikes,
       MIN(num_docks_available)                      AS min_docks,
       MAX(num_docks_available)                      AS max_docks,
       COUNT(DISTINCT num_docks_available)           AS distinct_dock_counts,
       SUM(CASE WHEN is_installed THEN 1 ELSE 0 END) AS installed_snapshots,
       SUM(CASE WHEN is_renting THEN 1 ELSE 0 END)   AS renting_snapshots,
       MIN(last_reported_ts)                         AS first_report,
       MAX(last_reported_ts)                         AS last_report
FROM gbfs.station_status_canonical
WHERE station_id IN ('bdc116cd-4d63-4693-846c-ec5073314007',
                     '9790606b-a00d-4d5e-b6ec-abd11c9d25b3',
                     '2177014969129222184',
                     'dfad8e49-7e1b-4376-90b4-7a449319f294',
                     '1885439359712500016')
GROUP BY station_id
ORDER BY station_id;
