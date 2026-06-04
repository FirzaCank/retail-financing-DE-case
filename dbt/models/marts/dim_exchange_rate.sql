{# ----------------------------------------------------------------------- #}
{# Model: dim_exchange_rate                                                 #}
{# Layer: marts (table)                                                     #}
{# Grain: one row per (currency, rate_date)                                 #}
{#                                                                          #}
{# Source: dbt seed exchange_rate_seed (CSV in dbt/seeds/). FX is a         #}
{# business dependency because the source Excel does not provide a         #}
{# conversion column. The seed holds monthly USD-IDR rates and a constant  #}
{# IDR-IDR rate of 1.00.                                                    #}
{# Unknown member: rate_sk = -1, used as the LEFT JOIN fallback when a     #}
{# transaction's currency cannot be matched to any rate row (which should  #}
{# not happen with the seeded coverage but is safeguarded).                 #}
{# ----------------------------------------------------------------------- #}

{{ config(
    materialized = 'table',
    tags = ['marts', 'dim']
) }}

WITH src AS (
    SELECT
        UPPER(currency)                      AS currency,
        CAST(rate_date AS DATE)              AS rate_date,
        CAST(rate_to_idr AS {{ t_numeric() }}) AS rate_to_idr
    FROM {{ ref('exchange_rate_seed') }}
),

with_sk AS (
    SELECT
        {{ surrogate_int("CONCAT(currency, '|', CAST(rate_date AS " ~ t_string() ~ "))") }} AS rate_sk,
        currency,
        rate_date,
        rate_to_idr
    FROM src
),

unknown AS (
    SELECT
        {{ unknown_member_sk() }}            AS rate_sk,
        '{{ unknown_member_nk() }}'          AS currency,
        CAST(NULL AS DATE)                   AS rate_date,
        CAST(NULL AS {{ t_numeric() }})      AS rate_to_idr
)

SELECT rate_sk, currency, rate_date, rate_to_idr FROM with_sk
UNION ALL
SELECT rate_sk, currency, rate_date, rate_to_idr FROM unknown
