{# fact_transactions: incremental MERGE on transaction_id, 3-day lookback to
   catch late arrivals (max observed lag 2 days). All dim joins are LEFT JOIN;
   broken FKs resolve to unknown member (_sk = -1). DQ-flagged rows stay in
   the fact with is_quarantined=TRUE and are mirrored to quarantine. #}

{{ config(
    materialized           = 'incremental',
    unique_key             = 'transaction_id',
    incremental_strategy   = 'merge',
    partition_by           = fact_partition(),
    cluster_by             = fact_cluster(),
    on_schema_change       = 'append_new_columns',
    tags                   = ['marts', 'fact']
) }}

WITH stg AS (
    SELECT *
    FROM {{ ref('stg_transactions') }}
    {% if is_incremental() %}
    WHERE updated_at >= (
        SELECT {{ lookback_ts('MAX(updated_at)', 3) }}
        FROM {{ this }}
    )
    {% endif %}
),

cust AS (
    SELECT customer_sk, customer_id, valid_from, valid_to
    FROM {{ ref('dim_customer') }}
),

-- SCD2 PIT join. BQ rejects correlated subqueries across tables, so we
-- LEFT JOIN all matching versions then QUALIFY to keep the latest per tx.
cust_pit AS (
    SELECT
        s.transaction_id,
        COALESCE(c.customer_sk, {{ unknown_member_sk() }}) AS customer_sk
    FROM stg s
    LEFT JOIN cust c
        ON  c.customer_id      = s.customer_id
        AND s.transaction_ts  >= c.valid_from
        AND (c.valid_to IS NULL OR s.transaction_ts < c.valid_to)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY s.transaction_id
        ORDER BY c.valid_from DESC
    ) = 1
),

brn AS (
    SELECT branch_sk, branch_id
    FROM {{ ref('dim_branch') }}
),

dt AS (
    SELECT date_sk, full_date
    FROM {{ ref('dim_date') }}
    WHERE date_sk != {{ unknown_member_sk() }}
),

rate AS (
    SELECT rate_sk, currency, rate_date
    FROM {{ ref('dim_exchange_rate') }}
    WHERE rate_sk != {{ unknown_member_sk() }}
),

-- Same BQ de-correlation pattern as cust_pit, for the FX rate join.
rate_pit AS (
    SELECT
        s.transaction_id,
        COALESCE(r.rate_sk, {{ unknown_member_sk() }}) AS rate_sk
    FROM stg s
    LEFT JOIN rate r
        ON  r.currency   = s.currency
        AND r.rate_date <= s.transaction_date
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY s.transaction_id
        ORDER BY r.rate_date DESC
    ) = 1
),

joined AS (
    SELECT
        {{ generate_sk(['s.transaction_id', 's.updated_at']) }} AS transaction_pk,
        s.transaction_id,
        cp.customer_sk,
        COALESCE(b.branch_sk, {{ unknown_member_sk() }}) AS branch_sk,
        COALESCE(d.date_sk,   {{ unknown_member_sk() }}) AS date_sk,
        rp.rate_sk,
        s.amount_original,
        s.currency,
        s.amount_idr,
        s.payment_method,
        s.transaction_status,
        s.channel,
        s.merchant_category,
        s.device_type,
        s.fraud_flag,
        s.promo_code,
        s.transaction_ts,
        s.updated_at,
        (s.dq_reason IS NOT NULL) AS is_quarantined,
        s.dq_reason,
        {{ now_ts() }} AS loaded_at
    FROM stg s
    LEFT JOIN cust_pit cp ON s.transaction_id = cp.transaction_id
    LEFT JOIN brn  b      ON s.branch_id      = b.branch_id
    LEFT JOIN dt   d      ON s.transaction_date = d.full_date
    LEFT JOIN rate_pit rp ON s.transaction_id = rp.transaction_id
)

SELECT
    transaction_pk,
    transaction_id,
    customer_sk,
    branch_sk,
    date_sk,
    rate_sk,
    amount_original,
    currency,
    amount_idr,
    payment_method,
    transaction_status,
    channel,
    merchant_category,
    device_type,
    fraud_flag,
    promo_code,
    transaction_ts,
    updated_at,
    is_quarantined,
    dq_reason,
    loaded_at
FROM joined
