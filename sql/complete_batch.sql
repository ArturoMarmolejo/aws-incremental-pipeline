-- Advance the checkpoint only to this batch's window_end, and never backwards.
UPDATE gbfs.pipeline_checkpoint
SET last_window_end = (SELECT window_end FROM gbfs.batch_log WHERE batch_id = '{{batch_id}}'),
    last_batch_id = '{{batch_id}}',
    updated_at = GETDATE()
WHERE pipeline_name = 'gbfs'
  AND last_window_end < (SELECT window_end FROM gbfs.batch_log WHERE batch_id = '{{batch_id}}');

UPDATE gbfs.batch_log
SET status = 'COMPLETED', finished_at = GETDATE()
WHERE batch_id = '{{batch_id}}';
