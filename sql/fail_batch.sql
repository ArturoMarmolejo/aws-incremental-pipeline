-- A failed batch never touches the checkpoint; the next run retries the same window.
UPDATE gbfs.batch_log
SET status = 'FAILED', finished_at = GETDATE()
WHERE batch_id = '{{batch_id}}';
