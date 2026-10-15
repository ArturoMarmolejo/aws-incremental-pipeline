import re
import sys
import time

import boto3

WORKGROUP = "arturo-gold-wg"
DATABASE = "dev"
client = boto3.client("redshift-data", region_name="us-east-2")


def run(sql):
    stmt = client.execute_statement(WorkgroupName=WORKGROUP, Database=DATABASE, Sql=sql)
    while True:
        info = client.describe_statement(Id=stmt["Id"])
        if info["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(1)
    if info["Status"] != "FINISHED":
        raise SystemExit(f"{info['Status']}: {info.get('Error')}\n--- statement ---\n{sql}")
    if info.get("HasResultSet"):
        for row in client.get_statement_result(Id=stmt["Id"])["Records"]:
            print([list(cell.values())[0] for cell in row])


# usage: run_sql.py FILE [key=value ...]   or   run_sql.py -c "SQL" [key=value ...]
if sys.argv[1] == "-c":
    text, extra = sys.argv[2], sys.argv[3:]
else:
    text, extra = open(sys.argv[1]).read(), sys.argv[2:]

# {{key}} placeholders are replaced only with safe characters
for item in extra:
    key, value = item.split("=", 1)
    if not re.fullmatch(r"[A-Za-z0-9_:.-]+", value):
        raise SystemExit(f"unsafe value for {key}: {value!r}")
    text = text.replace("{{" + key + "}}", value)
if "{{" in text:
    raise SystemExit("an unfilled {{placeholder}} is left in the SQL")

text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
for statement in [s.strip() for s in text.split(";") if s.strip()]:
    print("running:", statement.splitlines()[0][:70])
    run(statement)
print("done")
