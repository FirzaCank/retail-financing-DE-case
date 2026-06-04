-- incident4_data_freshness.sql
-- Root cause: marts stale 2 days, no way to tell source delay vs pipeline fail.
-- Fix: two-signal logic. Signal A = MAX(updated_at) in mart. Signal B = last
-- successful Cloud Run job. A-stale + B-fresh = source delay. A-stale + B-stale
-- = pipeline failure. freshness_alert.py covers the same split without the sink.

-- Q1. Mart freshness and SLO status (WARN 18h, BREACH 24h, CRITICAL 48h).
SELECT
    MAX(updated_at)                                                AS max_updated_at,
    MAX(transaction_ts)                                            AS max_transaction_ts,
    TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR)     AS hours_since_updated,
    TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(transaction_ts), HOUR) AS hours_since_transaction,
    CASE
        WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) > 24 THEN 'BREACH'
        WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) > 18 THEN 'WARN'
        ELSE 'OK'
    END AS freshness_status
FROM `PROJECT_ID.marts.fact_transactions`;

-- Q2. Per-day arrival pattern. Flat-line on recent days = source silence or
-- pipeline failure.
SELECT
    DATE(updated_at) AS load_day,
    COUNT(*)         AS rows_loaded,
    MIN(updated_at)  AS first_updated_at,
    MAX(updated_at)  AS last_updated_at
FROM `PROJECT_ID.marts.fact_transactions`
WHERE updated_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 14 DAY)
GROUP BY load_day
ORDER BY load_day DESC;

-- Q3. Two-signal classification. Requires ops.cloud_run_runs (Cloud Logging
-- export to BQ, provisioned out-of-band). Use freshness_alert.py
-- --run-results as an alternative when the sink is absent.
WITH mart AS (
    SELECT
        MAX(updated_at) AS max_updated_at,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) AS mart_lag_hours
    FROM `PROJECT_ID.marts.fact_transactions`
),
run AS (
    -- schema: run_id, job_name, status, started_at, finished_at
    SELECT
        MAX(finished_at) AS last_success_at,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(finished_at), HOUR) AS run_lag_hours
    FROM `PROJECT_ID.ops.cloud_run_runs`
    WHERE status = 'SUCCESS'
      AND job_name = 'retail-financing-daily'
)
SELECT
    mart.max_updated_at,
    mart.mart_lag_hours,
    run.last_success_at,
    run.run_lag_hours,
    CASE
        WHEN mart.mart_lag_hours > 24 AND run.run_lag_hours <= 24 THEN 'source_delay'
        WHEN mart.mart_lag_hours > 24 AND run.run_lag_hours  > 24 THEN 'pipeline_failure'
        WHEN mart.mart_lag_hours <= 24 AND run.run_lag_hours > 24 THEN 'orchestrator_broken_but_data_current'
        ELSE 'healthy'
    END AS diagnosis
FROM mart, run;

-- Q4. Raw vs mart recent row count: if raw has rows that mart doesn't, the
-- gap is in transform/load, not the source.
SELECT
    (SELECT COUNT(DISTINCT transaction_id) FROM `PROJECT_ID.raw.raw_transactions`
       WHERE SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', updated_at) >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 48 HOUR))
    AS raw_recent_tx,
    (SELECT COUNT(*) FROM `PROJECT_ID.marts.fact_transactions`
       WHERE updated_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 48 HOUR))
    AS mart_recent_tx;

-- Proposed SLOs:
--   Freshness: MAX(updated_at) within 24h on 99% of days
--   Run success: 99% of daily runs without manual intervention
--   Latency: run completes within 60 min of schedule
--   DQ: every broken-FK or invalid-amount row flagged is_quarantined=TRUE
--       and mirrored to quarantine; none silently dropped
