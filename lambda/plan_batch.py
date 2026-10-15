import datetime as dt
import os
import re
import time

import boto3

rsd = boto3.client("redshift-data")
WORKGROUP = os.environ["WORKGROUP"]
DATABASE = os.environ["DATABASE"]
PIPELINE = "gbfs"
OVERLAP = dt.timedelta(hours=2)          # late-data policy: re-read the last 2 hours
LOCK_MINUTES = 45                        # a STARTED batch younger than this is still running
FMT = "%Y-%m-%dT%H:%M:%SZ"               # the format the Glue jobs expect


def run(statement, params=None):
    kwargs = {"WorkgroupName": WORKGROUP, "Database": DATABASE, "Sql": statement}
    if params:
        kwargs["Parameters"] = [{"name": k, "value": v} for k, v in params.items()]
    statement_id = rsd.execute_statement(**kwargs)["Id"]
    while True:
        d = rsd.describe_statement(Id=statement_id)
        if d["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(0.5)
    if d["Status"] != "FINISHED":
        raise RuntimeError(f"SQL failed: {d.get('Error')}")
    if not d.get("HasResultSet"):
        return []
    records = rsd.get_statement_result(Id=statement_id)["Records"]
    return [[list(cell.values())[0] for cell in row] for row in records]


def claim(statements):
    """Run statements as ONE transaction and return the rows each one changed."""
    statement_id = rsd.batch_execute_statement(
        WorkgroupName=WORKGROUP, Database=DATABASE, Sqls=statements
    )["Id"]
    while True:
        d = rsd.describe_statement(Id=statement_id)
        if d["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(0.5)
    if d["Status"] != "FINISHED":
        raise RuntimeError(f"SQL batch failed: {d.get('Error')}")
    return [s.get("ResultRows", 0) for s in d.get("SubStatements", [])]


def parse(value):
    return dt.datetime.fromisoformat(value)


def result(batch_id, start, end, reused, skip=False):
    return {
        "batch_id": batch_id,
        "window_start": start.strftime(FMT),
        "window_end": end.strftime(FMT),
        "reused": reused,
        "skip": skip,
    }


def busy(batch_id, start, end):
    out = result(batch_id, start, end, reused=True, skip=True)
    out["reason"] = "busy"
    return out


def check_id(batch_id):
    if not re.fullmatch(r"b[0-9]{8}T[0-9]{6}Z", batch_id):
        raise ValueError(f"Unexpected batch id: {batch_id!r}")
    return batch_id


def handler(event, context):
    dry_run = event.get("dry_run", False)

    # 1. A batch that is not COMPLETED is retried with the SAME id and window.
    unfinished = run(
        "SELECT batch_id, window_start, window_end, status, "
        "DATEDIFF(minute, started_at, GETDATE()) FROM gbfs.batch_log "
        "WHERE status <> 'COMPLETED' ORDER BY window_end LIMIT 1"
    )
    if unfinished:
        batch_id, start, end, status, age_min = unfinished[0]
        batch_id = check_id(batch_id)
        start, end = parse(start), parse(end)
        # Overlap prevention: another execution is probably still working on it
        if status == "STARTED" and int(age_min) < LOCK_MINUTES:
            return busy(batch_id, start, end)
        if dry_run:
            return result(batch_id, start, end, reused=True)
        # Take it over atomically: only one execution can change the row
        counts = claim([
            "LOCK TABLE gbfs.batch_log",
            "UPDATE gbfs.batch_log SET status = 'STARTED', started_at = GETDATE() "
            f"WHERE batch_id = '{batch_id}' AND (status <> 'STARTED' "
            f"OR DATEDIFF(minute, started_at, GETDATE()) >= {LOCK_MINUTES})",
        ])
        if counts[1] == 0:
            return busy(batch_id, start, end)
        return result(batch_id, start, end, reused=True)

    # 2. Otherwise read the checkpoint and plan the next window.
    checkpoint = run(
        "SELECT last_window_end FROM gbfs.pipeline_checkpoint WHERE pipeline_name = :p",
        {"p": PIPELINE},
    )
    if not checkpoint:
        raise RuntimeError("Checkpoint not initialized: run sql/checkpoint_init.sql")
    last_end = parse(checkpoint[0][0])

    if "window_end" in event:
        end = dt.datetime.strptime(event["window_end"], FMT)
    else:
        now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
        end = now.replace(minute=now.minute // 30 * 30, second=0, microsecond=0)

    if end <= last_end:
        return result("none", last_end, end, reused=False, skip=True)

    start = last_end - OVERLAP
    batch_id = check_id("b" + end.strftime("%Y%m%dT%H%M%SZ"))
    if dry_run:
        return result(batch_id, start, end, reused=False)

    # Claim the window atomically: the row is inserted only if no batch is
    # unfinished and this batch id does not exist yet.
    counts = claim([
        "LOCK TABLE gbfs.batch_log",
        "INSERT INTO gbfs.batch_log (batch_id, window_start, window_end, status, started_at) "
        f"SELECT '{batch_id}', '{start:%Y-%m-%d %H:%M:%S}', '{end:%Y-%m-%d %H:%M:%S}', "
        "'STARTED', GETDATE() "
        "WHERE NOT EXISTS (SELECT 1 FROM gbfs.batch_log "
        f"WHERE batch_id = '{batch_id}' OR status <> 'COMPLETED')",
    ])
    if counts[1] == 0:
        return busy(batch_id, start, end)
    return result(batch_id, start, end, reused=False)
