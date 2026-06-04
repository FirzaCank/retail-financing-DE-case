-- File: 03_marts_tables.sql
-- Purpose: Reference DDL for the marts star schema. dbt manages the
--          authoritative DDL when models are built; this file documents the
--          target shape and is the source of truth when investigating
--          partition, cluster, and surrogate key definitions.
-- Layer: ddl / marts
-- Last updated: 2026-06-04

-- =========================================================================
-- marts.fact_transactions  (grain: one row per unique transaction_id)
-- Partition: DATE(transaction_ts) for reporting pruning.
-- Cluster:   customer_sk, branch_sk for selective joins and filters.
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.marts.fact_transactions`
(
    transaction_pk      STRING    NOT NULL,  -- surrogate (MD5 of transaction_id + updated_at)
    transaction_id      STRING    NOT NULL,  -- degenerate dimension for traceability
    customer_sk         INT64     NOT NULL,  -- FK -> dim_customer (-1 = unknown member)
    branch_sk           INT64     NOT NULL,  -- FK -> dim_branch    (-1 = unknown member)
    date_sk             INT64     NOT NULL,  -- FK -> dim_date      (YYYYMMDD)
    rate_sk             INT64     NOT NULL,  -- FK -> dim_exchange_rate
    amount_original     NUMERIC,             -- amount in source currency (nullable, quarantined if null)
    currency            STRING,              -- USD or IDR
    amount_idr          NUMERIC,             -- amount normalized to IDR via dim_exchange_rate.rate_to_idr
    payment_method      STRING,
    transaction_status  STRING,
    channel             STRING,
    merchant_category   STRING,
    device_type         STRING,
    fraud_flag          BOOL,
    promo_code          STRING,              -- nullable (4,838 null rows are legitimate sparse values, not errors)
    transaction_ts      TIMESTAMP NOT NULL,  -- cast from raw transaction_date
    updated_at          TIMESTAMP NOT NULL,  -- CDC watermark
    is_quarantined      BOOL      NOT NULL,  -- TRUE if any hard-fail DQ rule fired
    dq_reason           STRING,              -- pipe-delimited list of failed rules
    loaded_at           TIMESTAMP NOT NULL   -- mart row build time
)
PARTITION BY DATE(transaction_ts)
CLUSTER BY customer_sk, branch_sk
OPTIONS (
    description = 'Fact table at transaction grain. LEFT JOIN to dimensions; unmatched FKs map to unknown member (-1). Hard-fail rows copied to quarantine and flagged is_quarantined.',
    partition_expiration_days = NULL,
    require_partition_filter  = FALSE
);

-- =========================================================================
-- marts.dim_customer  (SCD Type 2; built from snapshots.snap_customers)
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.marts.dim_customer`
(
    customer_sk        INT64     NOT NULL,  -- surrogate (auto-generated or MD5)
    customer_id        STRING    NOT NULL,  -- natural key
    customer_name      STRING,
    city               STRING,
    registration_date  DATE,
    customer_status    STRING,
    customer_segment   STRING,
    email              STRING,
    phone_number       STRING,
    birth_date         DATE,
    occupation         STRING,
    income_band        STRING,
    kyc_status         STRING,
    valid_from         TIMESTAMP NOT NULL,  -- effective start (dbt_valid_from)
    valid_to           TIMESTAMP,           -- effective end (NULL if current)
    is_current         BOOL      NOT NULL,
    dbt_scd_id         STRING    NOT NULL
)
CLUSTER BY customer_id, is_current
OPTIONS (
    description = 'Customer dimension, SCD Type 2. History accrues forward from first load. Unknown member: customer_sk = -1, customer_id = UNKNOWN.'
);

-- =========================================================================
-- marts.dim_branch  (SCD Type 1; overwrite in place)
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.marts.dim_branch`
(
    branch_sk      INT64  NOT NULL,
    branch_id      STRING NOT NULL,
    branch_name    STRING,
    region         STRING,
    branch_status  STRING,
    branch_type    STRING,
    opening_date   DATE,
    manager_name   STRING,
    city           STRING
)
OPTIONS (
    description = 'Branch dimension, SCD Type 1. Overwrites in place. Unknown member: branch_sk = -1, branch_id = UNKNOWN. branch_name vs city mismatch (27/30 rows) is carried as-is, not auto-corrected.'
);

-- =========================================================================
-- marts.dim_date  (date spine)
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.marts.dim_date`
(
    -- Attribute columns are nullable: the unknown member row (date_sk = -1)
    -- carries NULLs for everything except the surrogate key.
    date_sk      INT64 NOT NULL,  -- YYYYMMDD integer
    full_date    DATE,
    year         INT64,
    quarter      INT64,
    month        INT64,
    day          INT64,
    day_of_week  INT64,           -- 1 = Sunday, 7 = Saturday (BigQuery default)
    is_weekend   BOOL
)
OPTIONS (
    description = 'Date dimension. Generated via GENERATE_DATE_ARRAY in dbt model. Spans 2020-01-01 to 2030-12-31.'
);

-- =========================================================================
-- marts.dim_exchange_rate  (from dbt seed)
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.marts.dim_exchange_rate`
(
    -- rate_date / rate_to_idr are nullable: the unknown member row
    -- (rate_sk = -1, currency = 'UNKNOWN') carries NULL rate values.
    rate_sk      INT64   NOT NULL,
    currency     STRING  NOT NULL,
    rate_date    DATE,
    rate_to_idr  NUMERIC
)
OPTIONS (
    description = 'Exchange rate dimension. Loaded from dbt seed exchange_rate_seed.csv. Business dependency: FX rates must be supplied. Unknown member: rate_sk = -1.'
);
