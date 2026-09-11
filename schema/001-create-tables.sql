-- An example table that shows the whole setup working: replicated across both servers,
-- moved to the warm disk after seven days, and deleted after ninety.
--
-- ON CLUSTER runs the statement on every replica through Keeper, so you apply it once.
-- {shard}, {replica}, {database} and {table} are filled in from the server's macros.
--
-- Replace this with your own tables. Never edit this file once it has run somewhere;
-- add a new numbered file instead.

CREATE TABLE IF NOT EXISTS events ON CLUSTER main (
    event_time   DateTime64(3)           NOT NULL,
    source       LowCardinality(String)  NOT NULL,
    name         LowCardinality(String)  NOT NULL,
    value        Float64                 NOT NULL DEFAULT 0,
    attributes   JSON                    DEFAULT '{}',
    ingested_at  DateTime                NOT NULL DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (source, name, event_time)
TTL
  event_time + INTERVAL 7 DAY TO VOLUME 'warm',
  event_time + INTERVAL 90 DAY DELETE
SETTINGS storage_policy = 'hot_warm';
