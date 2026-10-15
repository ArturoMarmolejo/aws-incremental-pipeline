import datetime
import re
import sys

import boto3
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["bucket", "window_start", "window_end", "batch_id"])
bucket, batch_id = args["bucket"], args["batch_id"]
UTC = datetime.timezone.utc
FMT = "%Y-%m-%dT%H:%M:%SZ"


def parse(text):
    return datetime.datetime.strptime(text, FMT).replace(tzinfo=UTC)


start, end = parse(args["window_start"]), parse(args["window_end"])
if start >= end:
    raise ValueError("window_start must be before window_end")

s3 = boto3.client("s3")


def list_files(feed):
    """Bronze files of one feed inside [start, end), found by listing only the hourly folders touched."""
    found = []
    hour = start.replace(minute=0, second=0, microsecond=0)
    while hour < end:
        prefix = f"bronze/gbfs/{feed}/dt={hour:%Y-%m-%d}/hour={hour:%H}/"
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                m = re.search(r"_(\d{8}T\d{6}Z)\.json$", obj["Key"])
                if m:
                    ts = datetime.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC)
                    if start <= ts < end:
                        found.append((ts, f"s3://{bucket}/{obj['Key']}"))
        hour += datetime.timedelta(hours=1)
    return sorted(found)


spark = GlueContext(SparkContext.getOrCreate()).spark_session
spark.conf.set("spark.sql.session.timeZone", "UTC")

# ---------- station_status: every file in the window ----------
status_paths = [p for _, p in list_files("station_status")]
print(f"batch {batch_id}: window [{args['window_start']}, {args['window_end']}) -> {len(status_paths)} status files")
if not status_paths:
    raise RuntimeError("no station_status files in the window; failing so the gap is noticed")

raw = spark.read.option("multiLine", True).json(status_paths)
rows = raw.select(
    F.col("last_updated").alias("snapshot_epoch"),
    F.input_file_name().alias("src"),
    F.explode("data.stations").alias("s"),
)
silver = rows.select(
    F.col("s.station_id").cast("string").alias("station_id"),
    F.from_unixtime("snapshot_epoch").cast("timestamp").alias("snapshot_ts"),
    F.col("s.num_bikes_available").cast("int").alias("num_bikes_available"),
    F.col("s.num_ebikes_available").cast("int").alias("num_ebikes_available"),
    F.col("s.num_docks_available").cast("int").alias("num_docks_available"),
    (F.col("s.is_installed") == 1).alias("is_installed"),
    (F.col("s.is_renting") == 1).alias("is_renting"),
    (F.col("s.is_returning") == 1).alias("is_returning"),
    F.from_unixtime("s.last_reported").cast("timestamp").alias("last_reported_ts"),
    F.to_timestamp(F.regexp_extract("src", r"_(\d{8}T\d{6}Z)\.json$", 1), "yyyyMMdd'T'HHmmss'Z'").alias("ingested_at"),
)

bad = silver.filter(F.col("station_id").isNull() | F.col("snapshot_ts").isNull()).count()
if bad:
    raise ValueError(f"{bad} status rows have a null station_id or snapshot_ts")

rows_in = silver.count()
silver = silver.dropDuplicates(["station_id", "snapshot_ts"])
rows_out = silver.count()
print(f"status rows in: {rows_in}, rows after dedup: {rows_out}")

target = f"s3://{bucket}/silver/gbfs/station_status/batch_id={batch_id}/"
silver.write.mode("overwrite").parquet(target)
print(f"wrote {target}")

# ---------- station_information: the latest file in the window feeds the station dimension ----------
info_files = list_files("station_information")
if not info_files:
    raise RuntimeError("no station_information file in the window; failing so the gap is noticed")
latest = info_files[-1][1]
print(f"station_information: using the latest of {len(info_files)} files: {latest}")

info_raw = spark.read.option("multiLine", True).json([latest])
info = info_raw.select(F.explode("data.stations").alias("s")).select(
    F.col("s.station_id").cast("string").alias("station_id"),
    F.col("s.name").cast("string").alias("name"),
    F.col("s.short_name").cast("string").alias("short_name"),
    F.col("s.lat").cast("double").alias("lat"),
    F.col("s.lon").cast("double").alias("lon"),
    F.col("s.capacity").cast("int").alias("capacity"),
)
if info.filter(F.col("station_id").isNull()).count():
    raise ValueError("station_information has rows without a station_id")
info = info.dropDuplicates(["station_id"])
info_target = f"s3://{bucket}/silver/gbfs/station_information/batch_id={batch_id}/"
info.write.mode("overwrite").parquet(info_target)
print(f"wrote {info_target} ({info.count()} stations)")
