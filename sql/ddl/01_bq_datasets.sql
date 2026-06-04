-- File: 01_bq_datasets.sql
-- Purpose: Create BigQuery datasets (schemas) for every pipeline layer.
-- Layer: ddl
-- Last updated: 2026-06-04
--
-- Run once per environment, before any dbt command. Replace `PROJECT_ID`
-- with the GCP project ID (matches `profiles.yml`). Location must match
-- the dbt profile location to avoid cross-region copies.

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.raw`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'Landing layer. Append-only batch loads from GCS. Includes ingestion_ts and source_file metadata. No transformations applied.'
);

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.staging`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'Staging layer (dbt views). Dedup on natural key, type cast, currency normalization, DQ flagging.'
);

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.marts`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'Marts layer (dbt tables). Kimball star: fact_transactions + conformed dimensions. Sole read source for reporting.'
);

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.quarantine`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'Quarantine layer. Rows failing hard DQ checks (null amount, negative amount, broken FK, future date). Retained for triage.'
);

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.snapshots`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'dbt snapshot output. snap_customers materializes SCD Type 2 history for dim_customer.'
);

CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.seeds`
OPTIONS (
    location    = 'asia-southeast2',
    description = 'Static reference data loaded via dbt seed. dim_exchange_rate source (FX is a business dependency).'
);
