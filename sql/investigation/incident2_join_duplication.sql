-- incident2_join_duplication.sql
-- Root cause: INNER JOIN on raw tables fans out 12,300 -> 12,329 rows.
-- Mechanism: +189 from 100 dup customer_id, -80 C99999 dropped, -80 B999 dropped = net +29.
-- Fix: dedup master in staging, LEFT JOIN with unknown member (_sk = -1).

-- Q1. Reproduce fan-out. Expected: after_inner_join=12,329, net_delta=+29.
WITH naive AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.branch_id,
        c.email,
        c.income_band,
        c.kyc_status,
        b.branch_name,
        b.branch_status
    FROM `PROJECT_ID.raw.raw_transactions` t
    INNER JOIN `PROJECT_ID.raw.raw_customers` c ON t.customer_id = c.customer_id
    INNER JOIN `PROJECT_ID.raw.raw_branches`  b ON t.branch_id   = b.branch_id
)
SELECT
    (SELECT COUNT(*) FROM `PROJECT_ID.raw.raw_transactions`) AS raw_transactions,
    (SELECT COUNT(*) FROM naive)                              AS after_inner_join,
    (SELECT COUNT(*) FROM naive) -
        (SELECT COUNT(*) FROM `PROJECT_ID.raw.raw_transactions`) AS net_delta;

-- Q2. Attribute non-determinism: same transaction gets different email/kyc
-- depending on which duplicate customer row the join picks.
SELECT
    t.transaction_id,
    t.customer_id,
    COUNT(DISTINCT c.email)       AS distinct_emails,
    COUNT(DISTINCT c.income_band) AS distinct_income_bands,
    COUNT(DISTINCT c.kyc_status)  AS distinct_kyc_statuses
FROM `PROJECT_ID.raw.raw_transactions` t
INNER JOIN `PROJECT_ID.raw.raw_customers` c
    ON t.customer_id = c.customer_id
GROUP BY t.transaction_id, t.customer_id
HAVING distinct_emails > 1
    OR distinct_income_bands > 1
    OR distinct_kyc_statuses > 1
ORDER BY distinct_kyc_statuses DESC
LIMIT 20;

-- Q3. Rows silently dropped by INNER JOIN on branch. Expected: 80 (branch_id = 'B999').
SELECT
    transaction_id,
    customer_id,
    branch_id,
    amount,
    transaction_date
FROM `PROJECT_ID.raw.raw_transactions`
WHERE branch_id NOT IN (SELECT branch_id FROM `PROJECT_ID.raw.raw_branches`);

-- Q4. Fix: dedup master in staging + LEFT JOIN. Row count must equal
-- distinct transaction_id in source.
WITH cust_dedup AS (SELECT * FROM `PROJECT_ID.staging.stg_customers`),
brn_dedup  AS (SELECT * FROM `PROJECT_ID.staging.stg_branches`),
fixed AS (
    SELECT
        t.transaction_id,
        COALESCE(c.customer_id, 'UNKNOWN') AS customer_id_resolved,
        COALESCE(b.branch_id,   'UNKNOWN') AS branch_id_resolved
    FROM `PROJECT_ID.staging.stg_transactions` t
    LEFT JOIN cust_dedup c ON t.customer_id = c.customer_id
    LEFT JOIN brn_dedup  b ON t.branch_id   = b.branch_id
)
SELECT
    (SELECT COUNT(DISTINCT transaction_id) FROM `PROJECT_ID.raw.raw_transactions`) AS source_unique_tx,
    COUNT(*)                                                                       AS fixed_row_count,
    COUNTIF(customer_id_resolved = 'UNKNOWN') AS resolved_to_unknown_customer,
    COUNTIF(branch_id_resolved   = 'UNKNOWN') AS resolved_to_unknown_branch
FROM fixed;

-- Q5. Prevention: assert exactly one fact row per transaction_id. Returns
-- 0 rows when the mart is clean.
SELECT
    transaction_id,
    COUNT(*) AS rows_in_fact
FROM `PROJECT_ID.marts.fact_transactions`
GROUP BY transaction_id
HAVING COUNT(*) > 1
ORDER BY rows_in_fact DESC
LIMIT 20;
