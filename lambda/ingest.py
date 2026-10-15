import datetime
import json
import os
import urllib.request

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]
BASE = "https://gbfs.citibikenyc.com/gbfs/en/"
FEEDS = ["station_status", "station_information"]


def handler(event, context):
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    written = []
    for name in FEEDS:
        with urllib.request.urlopen(BASE + name + ".json", timeout=20) as resp:
            body = resp.read()
        payload = json.loads(body)          # fails loudly if the feed is not valid JSON
        if "data" not in payload:
            raise ValueError(f"{name}: feed has no 'data' section")
        key = f"bronze/gbfs/{name}/dt={now:%Y-%m-%d}/hour={now:%H}/{name}_{stamp}.json"
        s3.put_object(
            Bucket=BUCKET,
            Key=key,
            Body=body,
            ContentType="application/json",
            Metadata={"ingested_at": now.isoformat()},
        )
        print(f"wrote s3://{BUCKET}/{key} ({len(body)} bytes)")
        written.append(key)
    return {"written": written}
