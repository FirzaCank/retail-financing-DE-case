-- File: 02_raw_tables.sql
-- Purpose: Raw layer table DDL. Append-only landing tables loaded by the
--          Cloud Run ingestion job from GCS daily CSV files.
-- Layer: ddl / raw
-- Last updated: 2026-06-04
--
-- Type policy: raw tables mirror source schema verbatim. Date and timestamp
-- columns are kept as STRING because the source Excel mixes formats
-- (registration_date is datetime; birth_date, opening_date, transaction_date
-- and updated_at are strings). Casting happens in staging. Two metadata
-- columns are added on every row: ingestion_ts and source_file.

-- =========================================================================
-- raw.raw_transactions
-- 14 source columns + 2 ingestion metadata columns. No partition or cluster
-- at raw layer (small footprint, only read by staging dedup).
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.raw.raw_transactions`
(
    transaction_id      STRING    NOT NULL,
    customer_id         STRING,
    branch_id           STRING,
    transaction_date    STRING,
    amount              NUMERIC,
    payment_method      STRING,
    transaction_status  STRING,
    channel             STRING,
    updated_at          STRING,
    merchant_category   STRING,
    device_type         STRING,
    currency            STRING,
    fraud_flag          STRING,
    promo_code          STRING,
    ingestion_ts        TIMESTAMP NOT NULL,
    source_file         STRING    NOT NULL
)
OPTIONS (
    description = 'Raw transactions, append-only. Mirrors source schema. Date/timestamp columns kept as STRING; cast in staging. fraud_flag arrives as Y/N string and is converted to BOOL in staging.'
);

-- =========================================================================
-- raw.raw_customers
-- 12 source columns + 2 ingestion metadata. 100 duplicate customer_id
-- values are expected per Phase 1 profiling.
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.raw.raw_customers`
(
    customer_id        STRING    NOT NULL,
    customer_name      STRING,
    city               STRING,
    registration_date  STRING,
    customer_status    STRING,
    customer_segment   STRING,
    email              STRING,
    phone_number       STRING,
    birth_date         STRING,
    occupation         STRING,
    income_band        STRING,
    kyc_status         STRING,
    ingestion_ts       TIMESTAMP NOT NULL,
    source_file        STRING    NOT NULL
)
OPTIONS (
    description = 'Raw customers, append-only. 100 duplicate customer_id values expected (conflicting attributes: email, phone, birth_date, occupation, income_band, kyc_status).'
);

-- =========================================================================
-- raw.raw_branches
-- 8 source columns + 2 ingestion metadata. 30 rows in source.
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.raw.raw_branches`
(
    branch_id      STRING    NOT NULL,
    branch_name    STRING,
    region         STRING,
    branch_status  STRING,
    branch_type    STRING,
    opening_date   STRING,
    manager_name   STRING,
    city           STRING,
    ingestion_ts   TIMESTAMP NOT NULL,
    source_file    STRING    NOT NULL
)
OPTIONS (
    description = 'Raw branches, append-only. 30 rows in source. branch_name vs city mismatch on 27 of 30 rows.'
);
