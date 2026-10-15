-- Initial boundary: end of the last manually verified window (test-002).
-- Runs only if no checkpoint row exists, so it is safe to repeat.
INSERT INTO gbfs.pipeline_checkpoint (pipeline_name, last_window_end, last_batch_id, updated_at)
SELECT 'gbfs', '2026-10-15 04:52:00', 'init', GETDATE()
WHERE NOT EXISTS (SELECT 1 FROM gbfs.pipeline_checkpoint WHERE pipeline_name = 'gbfs');

SELECT * FROM gbfs.pipeline_checkpoint;
