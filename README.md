# Automated Incremental AWS Data Pipeline (Citi Bike GBFS)

An incremental pipeline that ingests Citi Bike GBFS station data every 5 minutes and
processes it in 30-minute batches into a Redshift star schema. It runs on AWS and is
defined in Terraform.

## Architecture

EventBridge Scheduler (5 min) -> Lambda `ingest` -> S3 Bronze (raw JSON)

EventBridge Scheduler (30 min) -> Step Functions `arturo-gbfs-pipeline`:

1. Lambda `plan` picks the batch (batch_id, window_start, window_end) or skips if busy or nothing new
2. Glue `bronze_to_silver` (Bronze JSON -> Silver Parquet, explicit schema, dedup)
3. Glue `silver_to_redshift` (Silver -> landing table, batch-scoped)
4. Lambda `process` (landing -> canonical -> dimensions and fact)
5. Lambda `dq` (6 data quality checks; any non-zero count fails the batch)
6. Lambda `complete` (batch COMPLETED, checkpoint advances)

Any failure goes to Lambda `fail`, which marks the batch FAILED and leaves the checkpoint where it was.
See `architecture/` for the diagram.

## How incremental processing works

- **Checkpoint:** `gbfs.pipeline_checkpoint` stores `last_window_end` and the last batch id.
- **Window:** [last_window_end - 2h, now floored to 30 min). The 2-hour overlap is the
  late-data policy; duplicates from the overlap are removed by Silver dedup and by
  NOT EXISTS in the canonical load.
- **batch_id:** `bYYYYMMDDTHHMMSSZ`, derived from the window end, so it is deterministic.
- **Failure:** a batch that is not COMPLETED is retried with the same batch_id and window.
  The checkpoint only advances after the Gold build and all checks pass, and never backwards.
- **Overlap prevention:** the planner claims a batch inside one Redshift transaction
  (`LOCK TABLE` + conditional insert/update). A second execution that sees a STARTED batch
  younger than 45 minutes skips.
- **Idempotency:** every load is scoped to one batch_id and removes that batch's rows before
  inserting, so re-running a batch gives the same result.

## Repository layout

| Folder | Contents |
|---|---|
| `lambda/` | `ingest.py`, `plan_batch.py`, `batch_steps.py` |
| `glue/` | `bronze_to_silver.py`, `silver_to_redshift.py` |
| `sql/` | tables, process_batch, data_quality_checks, analytics, checkpoint, grants |
| `terraform/` | all infrastructure |
| `tools/` | `run_sql.py`, `run_batch.sh` (manual run and failure test) |
| `evidence/` | logs, query outputs, screenshots |
| `architecture/` | diagram |
| `homework-answers.md` | written answers |

## Deploy

```
cd terraform
export TF_VAR_redshift_admin_password   # only if your config asks for it; never commit it
terraform init
terraform fmt && terraform validate && terraform plan
terraform apply
```

Then create the tables and grants once:

```
python3 tools/run_sql.py sql/create_tables.sql
python3 tools/run_sql.py sql/checkpoint_init.sql
python3 tools/run_sql.py sql/grants.sql
```

## Turning schedules on and off

Both schedules default to OFF so nothing runs (and bills) by accident.

```
terraform apply -var ingest_schedule_enabled=true
terraform apply -var pipeline_schedule_enabled=true
terraform apply            # back to both OFF
```

## Running and recovering

- Start one run by hand: start an execution of `arturo-gbfs-pipeline` in Step Functions.
- After a failure, just start a new execution. It reuses the failed batch's id and window.
- Manual full run with a failure injected after the load step: `FAIL_AT=after_process tools/run_batch.sh`

## Checks

```
python3 tools/run_sql.py sql/data_quality_checks.sql
python3 tools/run_sql.py sql/analytics.sql
```

## Cost control

Turn both schedules off (above). Glue runs cost roughly $0.15 each; Redshift Serverless bills
only while in use. To remove everything, empty the project's S3 prefixes and run
`terraform destroy` only from this project's folder.

## Security

No credentials in code or git. Lambdas use IAM roles; the Redshift Data API connects as
`IAMR:<role name>`. Terraform state and `*.zip` are git-ignored.
