-- incident3_schema_evolution.sql
-- Root cause: source system added columns, rigid load failed on schema mismatch.
-- Fix: additive raw load (ALTER ADD COLUMN before append) + staging contract
-- that selects only known columns, so new raw columns land inert until promoted.

-- Q1. New columns in raw not in the expected contract. Returns 0 = no drift.
-- Includes ingestion_ts and source_file so they are not flagged as unexpected.
WITH expected AS (
    SELECT column_name FROM UNNEST([
        'transaction_id', 'customer_id', 'branch_id', 'transaction_date',
        'amount', 'payment_method', 'transaction_status', 'channel',
        'updated_at', 'merchant_category', 'device_type', 'currency',
        'fraud_flag', 'promo_code', 'ingestion_ts', 'source_file'
    ]) AS column_name
),
actual AS (
    SELECT column_name
    FROM `PROJECT_ID.raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'raw_transactions'
)
SELECT a.column_name AS new_or_unexpected_column
FROM actual a
LEFT JOIN expected e ON a.column_name = e.column_name
WHERE e.column_name IS NULL;

-- Q2. Inverse: expected columns that disappeared (source dropped a column).
WITH expected AS (
    SELECT column_name FROM UNNEST([
        'transaction_id', 'customer_id', 'branch_id', 'transaction_date',
        'amount', 'payment_method', 'transaction_status', 'channel',
        'updated_at', 'merchant_category', 'device_type', 'currency',
        'fraud_flag', 'promo_code'
    ]) AS column_name
),
actual AS (
    SELECT column_name
    FROM `PROJECT_ID.raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'raw_transactions'
)
SELECT e.column_name AS missing_expected_column
FROM expected e
LEFT JOIN actual a ON e.column_name = a.column_name
WHERE a.column_name IS NULL;

-- Q3. Sample rows from a newly added column to decide promote vs ignore.
-- Replace new_column_name with the value returned by Q1.
-- SELECT transaction_id, new_column_name, ingestion_ts, source_file
-- FROM `PROJECT_ID.raw.raw_transactions`
-- WHERE new_column_name IS NOT NULL
-- ORDER BY ingestion_ts DESC
-- LIMIT 100;

-- Q4. Recovery: staging selects explicit columns so new raw columns are
-- already inert. Re-run is safe without backfill.
-- dbt run --select stg_transactions+

-- Q5. Contract test: run daily. Fails fast on a dropped column, returns
-- 0 rows when schema is healthy.
WITH expected AS (
    SELECT column_name FROM UNNEST([
        'transaction_id', 'customer_id', 'branch_id', 'transaction_date',
        'amount', 'payment_method', 'transaction_status', 'channel',
        'updated_at', 'merchant_category', 'device_type', 'currency',
        'fraud_flag', 'promo_code'
    ]) AS column_name
),
actual AS (
    SELECT column_name
    FROM `PROJECT_ID.raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'raw_transactions'
)
SELECT
    COUNT(*) AS contract_violations,
    ARRAY_AGG(e.column_name) AS missing_columns
FROM expected e
LEFT JOIN actual a ON e.column_name = a.column_name
WHERE a.column_name IS NULL
HAVING COUNT(*) > 0;
