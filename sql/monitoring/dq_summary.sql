-- File: dq_summary.sql
-- Purpose: Aggregate quarantine table by failure reason. Shows the DQ
--          health trend so the team can tell whether failures are stable,
--          improving, or accelerating.
-- Layer: monitoring
-- Last updated: 2026-06-04
--
-- The dq_reason column is pipe-delimited (a row can fail multiple rules at
-- once). The CROSS JOIN UNNEST splits it so the aggregate counts each
-- reason independently, matching the Phase 1 measurements:
--   broken_fk_customer = 80, broken_fk_branch = 80,
--   null_amount = 179, negative_amount = 84, future_date = 64,
--   status_amount_conflict = 27.

WITH exploded AS (
    SELECT
        DATE(rejected_at) AS rejected_date,
        reason
    FROM `PROJECT_ID.quarantine.transactions_rejected`,
         UNNEST(SPLIT(dq_reason, '|')) AS reason
    WHERE reason != ''
),

agg AS (
    SELECT
        reason,
        COUNT(*)                       AS occurrences,
        MIN(rejected_date)             AS first_seen,
        MAX(rejected_date)             AS last_seen,
        COUNT(DISTINCT rejected_date)  AS days_seen
    FROM exploded
    GROUP BY reason
)

SELECT
    reason,
    occurrences,
    first_seen,
    last_seen,
    days_seen,
    SAFE_DIVIDE(occurrences, SUM(occurrences) OVER ()) AS pct_of_total
FROM agg
ORDER BY occurrences DESC;
