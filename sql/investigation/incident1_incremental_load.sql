-- incident1_incremental_load.sql
-- Root cause: updated_at lag up to 2 days misses same-day window; 300 duplicate
-- transaction_id cause dup-on-retry with naive INSERT.
-- Fix: incremental MERGE on transaction_id + 3-day lookback.

-- Q1. Late-arriving rows (lag > 1 fractional day). Expected ~6,100 post-dedup.
-- Use HOUR/24.0, not TIMESTAMP_DIFF(..., DAY) which truncates and undercounts.
SELECT
    COUNT(*)                                                    AS late_arriving_rows,
    AVG(TIMESTAMP_DIFF(updated_at, transaction_ts, HOUR) / 24.0) AS avg_lag_days,
    MAX(TIMESTAMP_DIFF(updated_at, transaction_ts, HOUR) / 24.0) AS max_lag_days
FROM `PROJECT_ID.staging.stg_transactions`
WHERE TIMESTAMP_DIFF(updated_at, transaction_ts, HOUR) / 24.0 > 1.0;

-- Q2. Duplicate transaction_id in raw (300 expected, each pair differs on updated_at).
SELECT
    transaction_id,
    COUNT(*)                AS row_count,
    COUNT(DISTINCT updated_at) AS distinct_updated_at
FROM `PROJECT_ID.raw.raw_transactions`
GROUP BY transaction_id
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 50;

-- Q3. Raw unique vs mart count. missing_rows should be 0 after MERGE fix.
WITH raw_distinct AS (
    SELECT COUNT(DISTINCT transaction_id) AS raw_unique_tx
    FROM `PROJECT_ID.raw.raw_transactions`
),
mart_count AS (
    SELECT COUNT(*) AS mart_tx
    FROM `PROJECT_ID.marts.fact_transactions`
)
SELECT
    raw_unique_tx,
    mart_tx,
    raw_unique_tx - mart_tx AS missing_rows
FROM raw_distinct, mart_count;

-- Q4. Lookback validation: any row exceeding 3-day lag would require widening
-- the window. Expected: 0 rows.
SELECT
    transaction_id,
    transaction_ts,
    updated_at,
    TIMESTAMP_DIFF(updated_at, transaction_ts, DAY) AS lag_days
FROM `PROJECT_ID.staging.stg_transactions`
WHERE TIMESTAMP_DIFF(updated_at, transaction_ts, DAY) > 3;

-- Q5. MERGE pattern (commented out): what dbt incremental generates, shown
-- here as a manual recovery reference.
-- MERGE INTO `PROJECT_ID.marts.fact_transactions` T
-- USING (
--     SELECT *
--     FROM `PROJECT_ID.staging.stg_transactions`
--     WHERE updated_at >= (
--         SELECT TIMESTAMP_SUB(MAX(updated_at), INTERVAL 3 DAY)
--         FROM `PROJECT_ID.marts.fact_transactions`
--     )
-- ) S
-- ON T.transaction_id = S.transaction_id
-- WHEN MATCHED AND S.updated_at > T.updated_at THEN UPDATE SET ...
-- WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
