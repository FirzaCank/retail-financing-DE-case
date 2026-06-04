-- File: freshness_check.sql
-- Purpose: Freshness SLO check, intended for daily scheduled execution
--          immediately after the dbt build completes.
-- Layer: monitoring
-- Last updated: 2026-06-04
--
-- Outcome: returns a single row with the most recent updated_at, hours
-- since that timestamp, and a categorical status. BigQuery Scheduled
-- Queries (or the freshness_alert.py Cloud Run job) consume this row and
-- raise an alert when status = 'BREACH'.

SELECT
    'fact_transactions'                                       AS table_name,
    MAX(updated_at)                                           AS last_updated_at,
    MAX(transaction_ts)                                       AS last_transaction_ts,
    TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) AS hours_since_updated,
    CASE
        WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) > 24 THEN 'BREACH'
        WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(updated_at), HOUR) > 18 THEN 'WARN'
        ELSE 'OK'
    END                                                       AS status,
    24                                                        AS slo_hours,
    CURRENT_TIMESTAMP()                                       AS checked_at
FROM `PROJECT_ID.marts.fact_transactions`;
