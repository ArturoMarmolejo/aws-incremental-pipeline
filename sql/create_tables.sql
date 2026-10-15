CREATE SCHEMA IF NOT EXISTS gbfs;

CREATE TABLE IF NOT EXISTS gbfs.pipeline_checkpoint (
    pipeline_name   VARCHAR(64) NOT NULL,
    last_window_end TIMESTAMP   NOT NULL,
    last_batch_id   VARCHAR(64),
    updated_at      TIMESTAMP DEFAULT GETDATE(),
    PRIMARY KEY (pipeline_name)
);

CREATE TABLE IF NOT EXISTS gbfs.batch_log (
    batch_id     VARCHAR(64) NOT NULL,
    window_start TIMESTAMP   NOT NULL,
    window_end   TIMESTAMP   NOT NULL,
    status       VARCHAR(16) NOT NULL,
    started_at   TIMESTAMP DEFAULT GETDATE(),
    finished_at  TIMESTAMP,
    PRIMARY KEY (batch_id)
);

CREATE TABLE IF NOT EXISTS gbfs.landing_station_status (
    batch_id             VARCHAR(64) NOT NULL,
    station_id           VARCHAR(64) NOT NULL,
    snapshot_ts          TIMESTAMP   NOT NULL,
    num_bikes_available  INT,
    num_ebikes_available INT,
    num_docks_available  INT,
    is_installed         BOOLEAN,
    is_renting           BOOLEAN,
    is_returning         BOOLEAN,
    last_reported_ts     TIMESTAMP,
    ingested_at          TIMESTAMP,
    loaded_at            TIMESTAMP DEFAULT GETDATE()
)
SORTKEY (batch_id);

CREATE TABLE IF NOT EXISTS gbfs.station_status_canonical (
    station_id           VARCHAR(64) NOT NULL,
    snapshot_ts          TIMESTAMP   NOT NULL,
    num_bikes_available  INT,
    num_ebikes_available INT,
    num_docks_available  INT,
    is_installed         BOOLEAN,
    is_renting           BOOLEAN,
    is_returning         BOOLEAN,
    last_reported_ts     TIMESTAMP,
    first_batch_id       VARCHAR(64) NOT NULL,
    loaded_at            TIMESTAMP DEFAULT GETDATE(),
    PRIMARY KEY (station_id, snapshot_ts)
)
SORTKEY (snapshot_ts);

CREATE TABLE IF NOT EXISTS gbfs.landing_station_information (
    batch_id   VARCHAR(64) NOT NULL,
    station_id VARCHAR(64) NOT NULL,
    name       VARCHAR(256),
    short_name VARCHAR(64),
    lat        DOUBLE PRECISION,
    lon        DOUBLE PRECISION,
    capacity   INT,
    loaded_at  TIMESTAMP DEFAULT GETDATE()
)
SORTKEY (batch_id);

-- Dimension 1: stations (Type 1: changed attributes are overwritten, no history)
CREATE TABLE IF NOT EXISTS gbfs.dim_station (
    station_key      BIGINT IDENTITY(1,1),
    station_id       VARCHAR(64) NOT NULL,
    name             VARCHAR(256),
    short_name       VARCHAR(64),
    lat              DOUBLE PRECISION,
    lon              DOUBLE PRECISION,
    capacity         INT,
    first_seen_batch VARCHAR(64),
    updated_at       TIMESTAMP DEFAULT GETDATE(),
    PRIMARY KEY (station_key)
);

-- Dimension 2: time, one row per hour
CREATE TABLE IF NOT EXISTS gbfs.dim_time (
    time_key    INT       NOT NULL,
    hour_start  TIMESTAMP NOT NULL,
    date_value  DATE      NOT NULL,
    hour_of_day SMALLINT  NOT NULL,
    day_of_week SMALLINT  NOT NULL,
    is_weekend  BOOLEAN   NOT NULL,
    PRIMARY KEY (time_key)
);

-- Fact. Grain: one row per station per feed snapshot.
CREATE TABLE IF NOT EXISTS gbfs.fact_station_status (
    station_key          BIGINT    NOT NULL,
    time_key             INT       NOT NULL,
    snapshot_ts          TIMESTAMP NOT NULL,
    num_bikes_available  INT,
    num_ebikes_available INT,
    num_docks_available  INT,
    is_renting           BOOLEAN,
    is_returning         BOOLEAN,
    first_batch_id       VARCHAR(64) NOT NULL,
    loaded_at            TIMESTAMP DEFAULT GETDATE()
)
SORTKEY (snapshot_ts);
