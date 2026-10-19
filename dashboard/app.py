import os
import time

import boto3
import pandas as pd
import streamlit as st

WORKGROUP = "arturo-gold-wg"
DATABASE = "dev"
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-2"
NUMERIC = {"int2", "int4", "int8", "float4", "float8", "numeric"}

client = boto3.client("redshift-data", region_name=REGION)


@st.cache_data(ttl=600, show_spinner="Querying Redshift...")
def query(sql: str) -> pd.DataFrame:
    statement_id = client.execute_statement(
        WorkgroupName=WORKGROUP, Database=DATABASE, Sql=sql
    )["Id"]
    while True:
        status = client.describe_statement(Id=statement_id)
        if status["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(0.5)
    if status["Status"] != "FINISHED":
        raise RuntimeError(status.get("Error", "Query failed"))
    if not status.get("HasResultSet"):
        return pd.DataFrame()

    rows, labels, types, token = [], None, None, None
    while True:
        kwargs = {"Id": statement_id}
        if token:
            kwargs["NextToken"] = token
        page = client.get_statement_result(**kwargs)
        if labels is None:
            labels = [c["label"] for c in page["ColumnMetadata"]]
            types = [c["typeName"] for c in page["ColumnMetadata"]]
        for record in page["Records"]:
            rows.append([None if "isNull" in v else next(iter(v.values())) for v in record])
        token = page.get("NextToken")
        if not token:
            break

    df = pd.DataFrame(rows, columns=labels)
    for label, type_name in zip(labels, types):
        if type_name in NUMERIC:
            df[label] = pd.to_numeric(df[label])
    return df


st.set_page_config(page_title="Citi Bike pipeline dashboard", layout="wide")
st.title("Citi Bike GBFS: pipeline and station dashboard")
st.caption(
    "Reads the Gold tables in Redshift Serverless. All times are UTC. "
    "Results are cached for 10 minutes to limit query cost."
)
if st.sidebar.button("Refresh data now"):
    st.cache_data.clear()
st.sidebar.write("Workgroup:", WORKGROUP)

FACT = "gbfs.fact_station_status"
DIM = "gbfs.dim_station"

# 1. Pipeline health
st.header("1. Pipeline health")
checkpoint = query("SELECT last_window_end, last_batch_id, updated_at FROM gbfs.pipeline_checkpoint")
fresh = query(f"SELECT MAX(snapshot_ts) AS latest_snapshot, COUNT(*) AS fact_rows, COUNT(DISTINCT station_key) AS stations FROM {FACT}")
dups = query(
    "SELECT COUNT(*) AS duplicate_keys FROM (SELECT station_id, snapshot_ts "
    "FROM gbfs.station_status_canonical GROUP BY station_id, snapshot_ts HAVING COUNT(*) > 1)"
)
c1, c2, c3, c4 = st.columns(4)
c1.metric("Checkpoint (last window end)", str(checkpoint.iloc[0]["last_window_end"]))
c2.metric("Latest snapshot in Gold", str(fresh.iloc[0]["latest_snapshot"]))
c3.metric("Fact rows", f"{int(fresh.iloc[0]['fact_rows']):,}")
c4.metric("Duplicate business keys", int(dups.iloc[0]["duplicate_keys"]))
st.write("Last 10 batches")
st.dataframe(
    query("SELECT batch_id, status, window_start, window_end, started_at, finished_at FROM gbfs.batch_log ORDER BY window_end DESC LIMIT 10"),
    use_container_width=True,
    hide_index=True,
)

# 2. System totals at the latest snapshot
st.header("2. System at the latest snapshot")
totals = query(
    f"SELECT SUM(num_bikes_available) AS bikes, SUM(num_ebikes_available) AS ebikes, "
    f"SUM(num_docks_available) AS docks, COUNT(*) AS stations FROM {FACT} "
    f"WHERE snapshot_ts = (SELECT MAX(snapshot_ts) FROM {FACT})"
)
t1, t2, t3, t4 = st.columns(4)
t1.metric("Bikes available", f"{int(totals.iloc[0]['bikes']):,}")
t2.metric("E-bikes available", f"{int(totals.iloc[0]['ebikes']):,}")
t3.metric("Free docks", f"{int(totals.iloc[0]['docks']):,}")
t4.metric("Stations reporting", f"{int(totals.iloc[0]['stations']):,}")
st.caption("A total at one moment is meaningful. Summing across snapshots would not be.")

# 3. Availability by hour
st.header("3. Average bikes per station by hour of day (UTC)")
hourly = query(
    f"SELECT t.hour_of_day, ROUND(AVG(f.num_bikes_available), 1) AS avg_bikes_per_station "
    f"FROM {FACT} f JOIN gbfs.dim_time t ON t.time_key = f.time_key "
    f"GROUP BY t.hour_of_day ORDER BY t.hour_of_day"
)
st.line_chart(hourly, x="hour_of_day", y="avg_bikes_per_station")

# 4. Station map
st.header("4. Station map (latest snapshot)")
latest = query(
    f"SELECT s.name, s.lat AS latitude, s.lon AS longitude, f.num_bikes_available, f.num_docks_available "
    f"FROM {FACT} f JOIN {DIM} s ON s.station_key = f.station_key "
    f"WHERE f.snapshot_ts = (SELECT MAX(snapshot_ts) FROM {FACT})"
)
choice = st.radio("Show", ["All stations", "No bikes", "No free docks"], horizontal=True)
shown = latest
if choice == "No bikes":
    shown = latest[latest["num_bikes_available"] == 0]
elif choice == "No free docks":
    shown = latest[latest["num_docks_available"] == 0]
st.write(f"{len(shown):,} stations")
st.map(shown[["latitude", "longitude"]])
search = st.text_input("Search a station name")
table = shown[shown["name"].str.contains(search, case=False, na=False)] if search else shown
st.dataframe(table.drop(columns=["latitude", "longitude"]), use_container_width=True, hide_index=True)

# 5. Most often empty
st.header("5. Stations most often empty (open for renting, capacity above 0)")
empty = query(
    f"SELECT s.name, s.capacity, COUNT(*) AS snapshots, "
    f"ROUND(100.0 * SUM(CASE WHEN f.num_bikes_available = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_empty, "
    f"COUNT(DISTINCT f.num_docks_available) AS distinct_dock_counts "
    f"FROM {FACT} f JOIN {DIM} s ON s.station_key = f.station_key "
    f"WHERE s.capacity > 0 AND f.is_renting = true "
    f"GROUP BY s.name, s.capacity HAVING COUNT(*) >= 20 "
    f"ORDER BY pct_empty DESC, snapshots DESC LIMIT 15"
)
empty["possibly_offline"] = (empty["pct_empty"] == 100) & (empty["distinct_dock_counts"] == 1)
st.dataframe(empty, use_container_width=True, hide_index=True)
st.caption(
    "possibly_offline = empty in every snapshot and the dock count never changed, "
    "so the station is probably not working rather than busy."
)
