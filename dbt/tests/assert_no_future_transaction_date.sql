-- File: assert_no_future_transaction_date.sql
-- Purpose: Detect transactions with a transaction_ts in the future that
--          have not been quarantined. Future-dated rows are flagged in
--          staging and routed to quarantine; this guards against any
--          path that bypasses the flag.
-- Layer: dbt singular test
-- Last updated: 2026-06-04
--
-- Phase 1 baseline (measured 2026-06-03): 64 transaction_date rows fall
-- strictly after the measurement date. Future-dated rows must be flagged by
-- stg_transactions.is_future_dated and land in quarantine. This test guards
-- the fact-side invariant only (the staging flag is verified by the
-- dq_reason audit). Severity: error.
--
-- Grain note: the staging flag uses DATE(transaction) > CURRENT_DATE(), so
-- this test must use the same DATE grain. Comparing transaction_ts against
-- CURRENT_TIMESTAMP() instead would flag a row dated today with a later
-- time-of-day that staging never quarantined, producing a spurious failure.

SELECT
    transaction_pk,
    transaction_id,
    transaction_ts,
    {{ day_diff('CAST(transaction_ts AS DATE)', 'CURRENT_DATE') }} AS days_in_future,
    is_quarantined,
    dq_reason
FROM {{ ref('fact_transactions') }}
WHERE CAST(transaction_ts AS DATE) > CURRENT_DATE
  AND is_quarantined = FALSE
