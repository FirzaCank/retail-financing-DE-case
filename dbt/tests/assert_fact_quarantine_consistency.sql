-- File: assert_fact_quarantine_consistency.sql
-- Purpose: Every quarantined fact row must have a non-empty dq_reason,
--          and every row with a non-empty dq_reason must be flagged
--          is_quarantined = TRUE. This catches integrity drift between
--          the boolean flag and the reason string.
-- Layer: dbt singular test
-- Last updated: 2026-06-04
-- Severity: error.

SELECT
    transaction_pk,
    transaction_id,
    is_quarantined,
    dq_reason
FROM {{ ref('fact_transactions') }}
WHERE (is_quarantined = TRUE  AND dq_reason IS NULL)
   OR (is_quarantined = FALSE AND dq_reason IS NOT NULL)
