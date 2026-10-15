#!/usr/bin/env bash
# Runs one incremental batch end to end. Any failure marks the batch FAILED
# and leaves the checkpoint untouched, so the next run retries the same window.
set -euo pipefail
cd "$(dirname "$0")/.."
export WORKGROUP=arturo-gold-wg DATABASE=dev AWS_DEFAULT_REGION=us-east-2

PLAN=$(cd lambda && python3 -c "import plan_batch, json; print(json.dumps(plan_batch.handler({}, None)))")
echo "PLAN: $PLAN"
get() { echo "$PLAN" | python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

if [ "$(get skip)" = "True" ]; then echo "Nothing new to process."; exit 0; fi
BATCH=$(get batch_id); START=$(get window_start); END=$(get window_end)

fail() {
  echo "FAILED at: $1"
  python3 tools/run_sql.py sql/fail_batch.sql batch_id="$BATCH"
  exit 1
}

wait_job() {  # $1 = job name, $2 = run id
  while true; do
    S=$(aws glue get-job-run --job-name "$1" --run-id "$2" --query JobRun.JobRunState --output text)
    echo "$(date +%T) $1 $S"
    case "$S" in STARTING|RUNNING|WAITING|STOPPING) sleep 20;; *) break;; esac
  done
  [ "$S" = "SUCCEEDED" ]
}

RUN=$(aws glue start-job-run --job-name arturo-gbfs-bronze-to-silver \
  --arguments "{\"--window_start\":\"$START\",\"--window_end\":\"$END\",\"--batch_id\":\"$BATCH\"}" \
  --query JobRunId --output text) || fail "start bronze-to-silver"
wait_job arturo-gbfs-bronze-to-silver "$RUN" || fail "bronze-to-silver"

RUN=$(aws glue start-job-run --job-name arturo-gbfs-silver-to-redshift \
  --arguments "{\"--batch_id\":\"$BATCH\"}" --query JobRunId --output text) || fail "start silver-to-redshift"
wait_job arturo-gbfs-silver-to-redshift "$RUN" || fail "silver-to-redshift"

python3 tools/run_sql.py sql/process_batch.sql batch_id="$BATCH" || fail "process_batch"

[ "${FAIL_AT:-}" = "after_process" ] && fail "simulated crash after process_batch" || true

DQ=$(python3 tools/run_sql.py sql/data_quality_checks.sql | tee "evidence/dq_$BATCH.txt") || fail "dq query"
echo "$DQ"
if echo "$DQ" | grep -Eq "^\['[a-z_]+', [1-9]"; then fail "data quality checks"; fi

python3 tools/run_sql.py sql/complete_batch.sql batch_id="$BATCH" || fail "complete_batch"
echo "BATCH $BATCH COMPLETED"
