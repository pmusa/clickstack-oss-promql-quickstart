-- Storage behind the Prometheus remote_write / remote_read handlers.
-- A TimeSeries table is a "meta" engine: it fans out into three inner tables
-- (data / tags / metrics) that you can also query directly with SQL.
SET allow_experimental_time_series_table = 1;

CREATE DATABASE IF NOT EXISTS prom;

CREATE TABLE IF NOT EXISTS prom.metrics ENGINE = TimeSeries;
