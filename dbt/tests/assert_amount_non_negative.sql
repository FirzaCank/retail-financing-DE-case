-- File: assert_amount_non_negative.sql
-- Purpose: A non-quarantined fact row must never carry a negative
--          amount_original. Negative amounts must be routed to quarantine.
-- Layer: dbt singular test
-- Last updated: 2026-06-04
--
-- Phase 1 baseline: 84 negative-amount rows in raw. All 84 must land in
-- quarantine with is_quarantined = TRUE and dq_reason containing
-- 'negative_amount'. The test fails if any negative row reaches the fact
-- with is_quarantined = FALSE.
-- Severity: error.

SELECT
    transaction_pk,
    transaction_id,
    amount_original,
    currency,
    is_quarantined,
    dq_reason
FROM {{ ref('fact_transactions') }}
WHERE amount_original < 0
  AND is_quarantined = FALSE
