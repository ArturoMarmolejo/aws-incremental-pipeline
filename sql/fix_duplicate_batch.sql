-- One-time cleanup: keep a single row for the batch that the race duplicated.
CREATE TABLE gbfs.tmp_batch_fix AS
SELECT batch_id, window_start, window_end, status,
       MIN(started_at) AS started_at, MAX(finished_at) AS finished_at
FROM gbfs.batch_log
WHERE batch_id = 'b20261015T173000Z'
GROUP BY 1, 2, 3, 4;
DELETE FROM gbfs.batch_log WHERE batch_id = 'b20261015T173000Z';
INSERT INTO gbfs.batch_log (batch_id, window_start, window_end, status, started_at, finished_at)
SELECT batch_id, window_start, window_end, status, started_at, finished_at FROM gbfs.tmp_batch_fix;
DROP TABLE gbfs.tmp_batch_fix;
