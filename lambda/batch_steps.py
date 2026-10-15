import os
import re
import time

import boto3

import plan_batch

rsd = boto3.client("redshift-data")
WORKGROUP = os.environ["WORKGROUP"]
DATABASE = os.environ["DATABASE"]

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = next(p for p in (os.path.join(HERE, "sql"), os.path.join(HERE, "..", "sql")) if os.path.isdir(p))


class DataQualityError(Exception):
    pass


def load_sql(filename, batch_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", batch_id):
        raise ValueError(f"Invalid batch_id: {batch_id!r}")
    with open(os.path.join(SQL_DIR, filename)) as f:
        lines = [ln for ln in f.read().splitlines() if not ln.strip().startswith("--")]
    text = "\n".join(lines).replace("{{batch_id}}", batch_id)
    return [s.strip() for s in text.split(";") if s.strip()]


def run_many(statements):
    """Run statements as ONE transaction: all succeed or none are applied."""
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


def handler(event, context):
    action = event["action"]

    if action == "plan":
        return plan_batch.handler(event.get("input", {}), context)

    batch_id = event["batch_id"]

    if action == "process":
        run_many(load_sql("process_batch.sql", batch_id))
        return {"batch_id": batch_id, "step": "process", "ok": True}

    if action == "dq":
        checks = {}
        for statement in load_sql("data_quality_checks.sql", batch_id):
            row = plan_batch.run(statement)[0]
            checks[row[0]] = int(row[1])
        bad = {name: n for name, n in checks.items() if n}
        if bad:
            raise DataQualityError(f"Data quality checks failed: {bad}")
        return {"batch_id": batch_id, "step": "dq", "checks": checks}

    if action == "complete":
        run_many(load_sql("complete_batch.sql", batch_id))
        return {"batch_id": batch_id, "step": "complete", "ok": True}

    if action == "fail":
        run_many(load_sql("fail_batch.sql", batch_id))
        return {"batch_id": batch_id, "step": "fail", "ok": True}

    raise ValueError(f"Unknown action: {action}")
