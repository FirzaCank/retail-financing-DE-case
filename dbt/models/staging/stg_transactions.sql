{# stg_transactions: dedup on transaction_id (keep latest updated_at), cast
   STRING dates, add point-in-time FX rate, flag DQ issues for quarantine. #}

{{ config(
    materialized = 'view',
    tags = ['staging', 'transactions']
) }}

WITH source AS (
    SELECT
        transaction_id,
        customer_id,
        branch_id,
        transaction_date,
        amount,
        payment_method,
        transaction_status,
        channel,
        updated_at,
        merchant_category,
        device_type,
        currency,
        fraud_flag,
        promo_code,
        ingestion_ts,
        source_file
    FROM {{ source('raw', 'raw_transactions') }}
),

deduped AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY transaction_id
        ORDER BY {{ parse_ts('updated_at') }} DESC NULLS LAST,
                 ingestion_ts DESC
    ) = 1
),

typed AS (
    SELECT
        transaction_id,
        customer_id,
        branch_id,
        {{ parse_ts('transaction_date') }} AS transaction_ts,
        CAST({{ parse_ts('transaction_date') }} AS DATE) AS transaction_date,
        CAST(amount AS {{ t_numeric() }}) AS amount_original,
        payment_method,
        transaction_status,
        channel,
        {{ parse_ts('updated_at') }} AS updated_at,
        merchant_category,
        device_type,
        UPPER(currency) AS currency,
        CASE UPPER(fraud_flag) WHEN 'Y' THEN TRUE WHEN 'N' THEN FALSE ELSE NULL END AS fraud_flag,
        promo_code,
        ingestion_ts,
        source_file
    FROM deduped
),

rates AS (
    SELECT
        currency,
        rate_date,
        rate_to_idr
    FROM {{ ref('exchange_rate_seed') }}
    WHERE currency IS NOT NULL
),

-- BQ rejects correlated subqueries in join predicates, so pick the latest
-- rate via LEFT JOIN all candidates + QUALIFY ROW_NUMBER instead.
fx_joined AS (
    SELECT
        t.*,
        r.rate_date    AS rate_date,
        r.rate_to_idr  AS rate_to_idr,
        CASE
            WHEN t.amount_original IS NULL          THEN NULL
            WHEN r.rate_to_idr     IS NULL          THEN NULL
            ELSE t.amount_original * r.rate_to_idr
        END AS amount_idr
    FROM typed t
    LEFT JOIN rates r
        ON  r.currency  = t.currency
        AND r.rate_date <= t.transaction_date
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.transaction_id
        ORDER BY r.rate_date DESC
    ) = 1
)

SELECT
    transaction_id,
    customer_id,
    branch_id,
    transaction_ts,
    transaction_date,
    amount_original,
    currency,
    amount_idr,
    rate_date,
    rate_to_idr,
    payment_method,
    transaction_status,
    channel,
    updated_at,
    merchant_category,
    device_type,
    fraud_flag,
    promo_code,
    ingestion_ts,
    source_file,

    (amount_original IS NULL)                                  AS is_null_amount,
    (amount_original < 0)                                      AS is_negative_amount,
    (transaction_date > CURRENT_DATE)                          AS is_future_dated,
    (customer_id = 'C99999')                                   AS is_broken_cust_fk,
    (branch_id = 'B999')                                       AS is_broken_branch_fk,
    (transaction_status = 'SUCCESS' AND amount_original < 0)   AS is_status_amount_conflict,

    -- Pipe-delimited reason string. Each failed rule contributes its tag;
    -- passing rules yield NULL and are dropped by the join (ARRAY_TO_STRING on
    -- BQ, CONCAT_WS on DuckDB, both skip NULLs).
    NULLIF(
        {{ concat_ws_skip_nulls('|', [
            "CASE WHEN amount_original IS NULL THEN 'null_amount' END",
            "CASE WHEN amount_original < 0 THEN 'negative_amount' END",
            "CASE WHEN transaction_date > CURRENT_DATE THEN 'future_date' END",
            "CASE WHEN customer_id = 'C99999' THEN 'broken_fk_customer' END",
            "CASE WHEN branch_id = 'B999' THEN 'broken_fk_branch' END",
            "CASE WHEN transaction_status = 'SUCCESS' AND amount_original < 0 THEN 'status_amount_conflict' END"
        ]) }},
        ''
    ) AS dq_reason
FROM fx_joined
