-- File: row_count_baseline.sql
-- Purpose: Row-count anomaly detection. Compares today's volume against
--          the trailing 7-day average and flags significant deviations
--          (under 50% or over 200%).
-- Layer: monitoring
-- Last updated: 2026-06-04
--
-- Usage: schedule daily right after the dbt build. Feed the result to an
-- alerting Cloud Function or read it from a Looker Studio scorecard.

WITH daily AS (
    SELECT
        DATE(transaction_ts) AS day,
        COUNT(*)             AS rows_loaded
    FROM `PROJECT_ID.marts.fact_transactions`
    WHERE DATE(transaction_ts) >= DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY)
    GROUP BY day
),

baseline AS (
    SELECT AVG(rows_loaded) AS avg_7d
    FROM daily
    WHERE day BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
                  AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
),

today AS (
    SELECT rows_loaded AS today_count
    FROM daily
    WHERE day = CURRENT_DATE()
)

SELECT
    CURRENT_DATE()           AS check_date,
    today.today_count        AS today_count,
    baseline.avg_7d          AS trailing_7d_avg,
    SAFE_DIVIDE(today.today_count, baseline.avg_7d) AS ratio_to_baseline,
    CASE
        WHEN today.today_count IS NULL                            THEN 'NO_DATA_TODAY'
        WHEN today.today_count < baseline.avg_7d * 0.5            THEN 'LOW_VOLUME'
        WHEN today.today_count > baseline.avg_7d * 2.0            THEN 'HIGH_VOLUME'
        ELSE 'OK'
    END                       AS status
FROM today, baseline;
