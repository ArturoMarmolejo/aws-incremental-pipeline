import re
import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["bucket", "batch_id", "connection_name", "TempDir"])
bucket, batch_id = args["bucket"], args["batch_id"]

# batch_id goes into a SQL statement below, so accept only safe characters
if not re.fullmatch(r"[A-Za-z0-9_-]+", batch_id):
    raise ValueError(f"unsafe batch_id: {batch_id!r}")

glue_context = GlueContext(SparkContext.getOrCreate())
spark = glue_context.spark_session

STATUS_COLUMNS = [
    "batch_id", "station_id", "snapshot_ts",
    "num_bikes_available", "num_ebikes_available", "num_docks_available",
    "is_installed", "is_renting", "is_returning", "last_reported_ts", "ingested_at",
]
INFO_COLUMNS = ["batch_id", "station_id", "name", "short_name", "lat", "lon", "capacity"]


def load(dataset, table, columns):
    source = f"s3://{bucket}/silver/gbfs/{dataset}/batch_id={batch_id}/"
    df = spark.read.parquet(source)
    rows = df.count()
    print(f"batch {batch_id}: {rows} {dataset} rows read from {source}")
    if rows == 0:
        raise RuntimeError(f"the Silver {dataset} batch is empty; failing instead of loading nothing")
    df = df.withColumn("batch_id", F.lit(batch_id)).select(*columns)
    # delete this batch's earlier rows, then load: a retry cannot create duplicates
    glue_context.write_dynamic_frame.from_jdbc_conf(
        frame=DynamicFrame.fromDF(df, glue_context, dataset),
        catalog_connection=args["connection_name"],
        connection_options={
            "dbtable": table,
            "database": "dev",
            "preactions": f"DELETE FROM {table} WHERE batch_id = '{batch_id}';",
        },
        redshift_tmp_dir=args["TempDir"],
    )
    print(f"batch {batch_id}: loaded {rows} rows into {table}")


load("station_status", "gbfs.landing_station_status", STATUS_COLUMNS)
load("station_information", "gbfs.landing_station_information", INFO_COLUMNS)
