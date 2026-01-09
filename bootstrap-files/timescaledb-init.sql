\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'f1', 'f1pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'f1');
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', 'f1', 'f1')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'f1');
\gexec

GRANT ALL PRIVILEGES ON DATABASE f1 TO f1;

\c f1

SET ROLE f1;

CREATE TABLE IF NOT EXISTS telemetry_stream (
  ts timestamptz NOT NULL DEFAULT now(),
  frame integer NOT NULL,
  session_uid bigint,

  speed_kph integer,
  rpm integer,
  gear smallint,
  throttle real,
  brake real,
  drs smallint,

  tyre_temp_surface_rl smallint,
  tyre_temp_surface_rr smallint,
  tyre_temp_surface_fl smallint,
  tyre_temp_surface_fr smallint,

  tyre_temp_inner_rl smallint,
  tyre_temp_inner_rr smallint,
  tyre_temp_inner_fl smallint,
  tyre_temp_inner_fr smallint,

  brake_temp_rl smallint,
  brake_temp_rr smallint,
  brake_temp_fl smallint,
  brake_temp_fr smallint,

  engine_temp smallint
);

CREATE INDEX IF NOT EXISTS telemetry_stream_ts_idx ON telemetry_stream (ts DESC);