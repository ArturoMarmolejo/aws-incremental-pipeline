# Automated Incremental AWS Data Pipeline (Citi Bike GBFS)

An incremental pipeline that ingests Citi Bike GBFS station data every 5 minutes and
processes it in 30-minute batches into a Redshift star schema. It runs on AWS and is
defined in Terraform. A Streamlit dashboard reads the Gold tables.

## Status

| Component | Status | Notes |
|---|---|---|
| Terraform | Complete | `terraform fmt` and `terraform validate` pass |
| Lambda ingest to S3 Bronze | Complete | Station information and station status, partitioned by `dt=` and `hour=` |
| Step Functions | Complete | Plan, ETL, load, checks, complete; any failure goes to a fail step |
| Glue Bronze to Silver | Complete | Incremental window, explicit schema, dedup, per-batch output |
| Glue Silver to Redshift | Complete | Batch-scoped load into the landing table |
| Redshift star schema | Complete | `dim_station`, `dim_time`, `fact_station_status` |
| Streamlit dashboard | Built and tested locally | `dashboard/app.py` (not run this weekend) |
| Bedrock natural-language SQL | Design only | Not deployed; the assignment does not require it |
| `build_sql_prompt()` exercise | Complete | `ai/build_sql_prompt.py`; example output in `evidence/build_sql_prompt_output.txt` |

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

## Failure handling and duplicate avoidance

**Failures.** Glue jobs have no automatic retries (`max_retries = 0`), so a failure shows up
immediately. Bronze-to-Silver also raises an error on an empty window, an invalid window or
null keys, so gaps are noticed instead of silently skipped. Step Functions sends any failure to
the `fail` step, which marks the batch FAILED. The checkpoint stays put, so the next run
retries the same window.

**Duplicates.** Overlapping windows mean the same observation can be loaded by several
batches. Silver is written per batch with overwrite, Bronze-to-Silver deduplicates on
`(station_id, snapshot_ts)`, and the canonical and fact tables keep one row per
`(station_id, snapshot_ts)`. The landing table keeps every copy (up to 5 per observation) as an
audit trail.

## Reviews completed

**Terraform:** `terraform fmt -recursive` and `terraform validate` succeed.

**IAM:** seven roles, each scoped to one purpose. Ingest can only write to `bronze/gbfs/*`.
Glue can read Bronze and scripts and read/write/delete only the Silver and temp prefixes.
Step Functions can only invoke the orchestrator Lambda and the two named Glue jobs. Both
schedulers can only invoke or start one specific target. The only resource wildcard is the
Redshift Data API on the orchestrator, which is needed for statement-status calls; credentials
are limited to the `arturo-gold-wg` workgroup.

**Glue (`bronze_to_silver.py`):** reads only the hourly folders in the batch window and filters
files by their ingest timestamp; casts types explicitly and flattens the station arrays;
deduplicates on `(station_id, snapshot_ts)`; writes one folder per batch with overwrite so a
re-run is idempotent.

## Analytical queries

All queries are in `sql/homework_exercises.sql`.

| # | Question | Tables |
|---|---|---|
| 1 | Which 10 stations have the highest average available bikes? | `fact_station_status`, `dim_station` |
| 2 | What is the latest status of each station? (`ROW_NUMBER` with `QUALIFY`) | `fact_station_status`, `dim_station` |
| 3 | Are there duplicate observations in the canonical table? (expected 0 rows) | `station_status_canonical` |
| 4 | How many copies of an observation exist in landing? | `landing_station_status` |
| 5 | Which open stations with real capacity are most often empty? | `fact_station_status`, `dim_station` |
| 6 | How does average availability change by hour, weekday vs weekend? | `fact_station_status`, `dim_time` |

Queries 1, 2, 5 and 6 are the analytical queries; 3 and 4 are data quality checks. Query 5
excludes stations with capacity 0 and stations not renting, because the first version ranked
offline stations as "always empty".

## Repository layout

| Folder | Contents |
|---|---|
| `lambda/` | `ingest.py`, `plan_batch.py`, `batch_steps.py` |
| `glue/` | `bronze_to_silver.py`, `silver_to_redshift.py` |
| `sql/` | tables, process_batch, data_quality_checks, analytics, homework_exercises, checkpoint, grants |
| `dashboard/` | Streamlit app (`app.py`) |
| `ai/` | `build_sql_prompt.py` (prompt builder for the AI exercise) |
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

Prerequisite created by hand: the Glue connection `arturo-redshift-vpc` (see Known gaps).

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

## Dashboard

```
source .venv/bin/activate
streamlit run dashboard/app.py
```

Then open http://localhost:8501. It reads Redshift through the Data API and caches results for
10 minutes. It was not run this weekend because that would start Redshift queries.

## Checks

```
python3 tools/run_sql.py sql/data_quality_checks.sql
python3 tools/run_sql.py sql/analytics.sql
```

## Known gaps and blockers

- The Glue connection `arturo-redshift-vpc` was created manually in the console and is not yet
  managed by Terraform (import it).
- The orchestrator's `ExecuteStatement` permission could be scoped to the workgroup ARN
  instead of `*`.
- Bronze-to-Silver deduplication keeps an arbitrary row among duplicates; choosing the latest
  `ingested_at` would make it deterministic.
- The dashboard uses `use_container_width`, which Streamlit has deprecated; replace with
  `width='stretch'`.
- Bedrock natural-language SQL is a design only; nothing is deployed.

## Monday verification (2026-10-19)

- [x] Query 6 and the corrected query 5 ran against Redshift (`evidence/q5_q6_output.txt`)
- [x] One batch ran with `tools/run_batch.sh`: `b20261019T143000Z` COMPLETED, all 6 data
      quality checks returned 0, checkpoint advanced to 2026-10-19 14:30 (`evidence/run_batch_monday.txt`)
- [x] Dashboard loaded against live data
- [x] Both schedules confirmed DISABLED afterwards

Findings: the data covers weekdays only (2026-10-15), so query 6 cannot yet compare weekday
and weekend. Five stations were empty in 100% of snapshots even after filtering offline
stations; the data does not show whether that is a rebalancing problem or a sensor fault.

## Weekend note

No AWS resources were started over the weekend. Cloud testing was done on Monday. Both schedules stayed disabled throughout.

## Cost control

Turn both schedules off (above). Glue runs cost roughly $0.15 each; Redshift Serverless bills
only while in use. To remove everything, empty the project's S3 prefixes and run
`terraform destroy` only from this project's folder.

## Security

No credentials in code or git. Lambdas use IAM roles; the Redshift Data API connects as
`IAMR:<role name>`. Terraform state and `*.zip` are git-ignored.
