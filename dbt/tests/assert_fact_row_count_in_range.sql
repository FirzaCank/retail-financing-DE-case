-- File: assert_fact_row_count_in_range.sql
-- Purpose: Smoke test on overall fact volume. Catches catastrophic loss
--          (e.g. an INNER JOIN regression dropping 80 broken-FK rows or a
--          dedup bug collapsing the table) by asserting that today's row
--          count is within a sane range relative to the trailing 7-day
--          average.
-- Layer: dbt singular test
-- Last updated: 2026-06-04
--
-- Tolerance: today must be within 50% to 200% of the 7-day average. The
-- band is intentionally generous for the early stage (low traffic days);
-- tighten once at production volume. Severity: warn (not error) because
-- legitimate spikes / quiet days can trigger.

WITH counts AS (
    SELECT
        CAST(transaction_ts AS DATE) AS day,
        COUNT(*)                     AS row_count
    FROM {{ ref('fact_transactions') }}
    WHERE CAST(transaction_ts AS DATE) >= {{ date_minus_days(7) }}
    GROUP BY day
),

stats AS (
    SELECT
        AVG(row_count) AS avg_7d,
        (SELECT row_count FROM counts WHERE day = CURRENT_DATE) AS today_count
    FROM counts
    WHERE day < CURRENT_DATE
)

SELECT
    today_count,
    avg_7d
FROM stats
WHERE avg_7d IS NOT NULL
  AND today_count IS NOT NULL
  AND (today_count < avg_7d * 0.5 OR today_count > avg_7d * 2.0)
