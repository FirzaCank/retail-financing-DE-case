-- File: 04_quarantine.sql
-- Purpose: Quarantine layer table DDL. Hard-failed transaction rows that
--          cannot safely reach `marts.fact_transactions` are isolated here
--          with the failure reason for triage and trend reporting.
-- Layer: ddl / quarantine
-- Last updated: 2026-06-04
--
-- Rationale: dropping rows silently destroys evidence and hides upstream
-- bugs. Quarantine preserves every offending row, the originating raw
-- timestamp, and a pipe-delimited dq_reason so analysts can group failures
-- (e.g. broken FK vs negative amount) without rerunning the pipeline.

-- =========================================================================
-- quarantine.transactions_rejected
-- Typed staging columns (post-cast) + DQ metadata. dbt materializes this
-- table from models/quarantine/transactions_rejected.sql; this DDL is the
-- reference shape and must match the model's output types: transaction_date
-- is DATE, updated_at is TIMESTAMP, fraud_flag is BOOL (all cast in staging),
-- not the raw STRING forms. No partition or cluster beyond rejected_at at
-- current volume (estimated ~500 rows per day at 20M/day scale assuming the
-- Phase 1 failure-rate proportions hold).
-- =========================================================================
CREATE TABLE IF NOT EXISTS `PROJECT_ID.quarantine.transactions_rejected`
(
    transaction_id      STRING,
    customer_id         STRING,
    branch_id           STRING,
    transaction_date    DATE,
    amount              NUMERIC,
    payment_method      STRING,
    transaction_status  STRING,
    channel             STRING,
    updated_at          TIMESTAMP,
    merchant_category   STRING,
    device_type         STRING,
    currency            STRING,
    fraud_flag          BOOL,
    promo_code          STRING,
    ingestion_ts        TIMESTAMP,
    source_file         STRING,
    dq_reason           STRING    NOT NULL,  -- pipe-delimited: 'broken_fk_customer|broken_fk_branch|null_amount|negative_amount|future_date|status_amount_conflict'
    rejected_at         TIMESTAMP NOT NULL   -- when the staging build flagged the row
)
PARTITION BY DATE(rejected_at)
OPTIONS (
    description = 'Rows that failed hard DQ checks during staging. Retained for triage. Categories: broken_fk_customer (80 rows in Phase 1), broken_fk_branch (80), null_amount (179), negative_amount (84), future_date (64), status_amount_conflict (27).',
    partition_expiration_days = 365
);
