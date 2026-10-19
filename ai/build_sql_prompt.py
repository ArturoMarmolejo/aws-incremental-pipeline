"""Builds the prompt sent to an LLM to generate Amazon Redshift SQL"""

RULES = """You are an expert Amazon Redshift SQL assistant.

Follow these rules exactly:
1. Generate only valid Amazon Redshift SQL (PostgreSQL-compatible syntax).
2. Use only the tables and columns listed in the schema below. Do not invent
   tables, columns, or functions. If the question cannot be answered with the
   given schema, reply with: CANNOT_ANSWER
3. Generate read-only SQL: a single SELECT statement. Never use INSERT, UPDATE,
   DELETE, DROP, ALTER, CREATE, TRUNCATE, or GRANT.
4. Use the join keys described in the documentation.
5. Return only the SQL query, with no explanation and no markdown fences."""

def build_sql_prompt(question, schema, documentation):
    return f"""{RULES}

SCHEMA:
{schema.strip()}

DOCUMENTATION:
{documentation.strip()}

QUESTION:
{question.strip()}

SQL:"""

SAMPLE_SCHEMA = """
gbfs.dim_station(station_key BIGINT, station_id VARCHAR, name VARCHAR,
                 short_name VARCHAR, lat DOUBLE PRECISION, lon DOUBLE PRECISION,
                 capacity INT)
gbfs.dim_time(time_key INT, hour_start TIMESTAMP, date_value DATE,
              hour_of_day SMALLINT, day_of_week SMALLINT, is_weekend BOOLEAN)
gbfs.fact_station_status(station_key BIGINT, time_key INT, snapshot_ts TIMESTAMP,
                         num_bikes_available INT, num_ebikes_available INT,
                         num_docks_available INT, is_renting BOOLEAN,
                         is_returning BOOLEAN)
"""

SAMPLE_DOCUMENTATION = """
- fact_station_status has one row per station per feed snapshot (every ~5 minutes).
- Join: fact_station_status.station_key = dim_station.station_key
- Join: fact_station_status.time_key = dim_time.time_key
- num_bikes_available counts all bikes, including e-bikes (num_ebikes_available).
- For questions about current availability, use only the most recent snapshot_ts
  per station (ROW_NUMBER() OVER (PARTITION BY station_key ORDER BY snapshot_ts DESC)
  with QUALIFY = 1).
- Stations with capacity 0 or is_renting = false are not in service.
"""


if __name__ == "__main__":
    question = "Which 10 Citi Bike stations have the highest number of available bicycles?"
    print(build_sql_prompt(question, SAMPLE_SCHEMA, SAMPLE_DOCUMENTATION))
