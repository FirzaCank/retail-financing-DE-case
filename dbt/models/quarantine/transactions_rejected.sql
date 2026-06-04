{# ----------------------------------------------------------------------- #}
{# Model: transactions_rejected                                             #}
{# Layer: quarantine (table, incremental)                                   #}
{# Grain: one row per (transaction_id, updated_at) that failed a hard DQ   #}
{#        rule in staging.                                                  #}
{#                                                                          #}
{# Purpose: hard-fail rows must not be silently dropped. The fact table    #}
{# carries them with is_quarantined = TRUE so totals stay complete, and   #}
{# this table also persists them under the quarantine schema for analysts #}
{# who want to triage by reason without filtering the fact.                #}
{#                                                                          #}
{# Incremental policy mirrors fact_transactions: MERGE on transaction_id   #}
{# with a 3-day lookback window so retries are idempotent and late         #}
{# arrivals are re-captured.                                                #}
{# ----------------------------------------------------------------------- #}

{{ config(
    materialized           = 'incremental',
    schema                 = 'quarantine',
    alias                  = 'transactions_rejected',
    unique_key             = 'transaction_id',
    incremental_strategy   = 'merge',
    partition_by           = quarantine_partition(),
    on_schema_change       = 'append_new_columns',
    tags                   = ['quarantine']
) }}

WITH src AS (
    SELECT *
    FROM {{ ref('stg_transactions') }}
    WHERE dq_reason IS NOT NULL
    {% if is_incremental() %}
      AND updated_at >= (
          SELECT {{ lookback_ts('MAX(updated_at)', 3) }}
          FROM {{ this }}
      )
    {% endif %}
)

SELECT
    transaction_id,
    customer_id,
    branch_id,
    transaction_date,
    amount_original    AS amount,
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
    source_file,
    dq_reason,
    {{ now_ts() }} AS rejected_at
FROM src
