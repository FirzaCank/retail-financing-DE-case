{# dim_customer: SCD2 sourced from snap_customers. Earliest version per customer
   gets valid_from floored to 1900-01-01 so transactions predating the first
   snapshot run don't fall through to the unknown member. #}

{{ config(
    materialized = 'table',
    tags = ['marts', 'dim']
) }}

WITH snap AS (
    SELECT
        dbt_scd_id     AS customer_sk_str,   -- string surrogate per version
        customer_id,
        customer_name,
        city,
        registration_date,
        customer_status,
        customer_segment,
        email,
        phone_number,
        birth_date,
        occupation,
        income_band,
        kyc_status,
        dbt_valid_from AS valid_from,
        dbt_valid_to   AS valid_to,
        (dbt_valid_to IS NULL) AS is_current,
        dbt_scd_id
    FROM {{ ref('snap_customers') }}
),

with_int_sk AS (
    SELECT
        {{ surrogate_int('customer_sk_str') }} AS customer_sk,
        customer_id,
        customer_name,
        city,
        registration_date,
        customer_status,
        customer_segment,
        email,
        phone_number,
        birth_date,
        occupation,
        income_band,
        kyc_status,
        CASE
            WHEN valid_from = MIN(valid_from) OVER (PARTITION BY customer_id)
            THEN TIMESTAMP '1900-01-01 00:00:00'
            ELSE valid_from
        END AS valid_from,
        valid_to,
        is_current,
        dbt_scd_id
    FROM snap
),

unknown AS (
    SELECT
        {{ unknown_member_sk() }}            AS customer_sk,
        '{{ unknown_member_nk() }}'          AS customer_id,
        'Unknown Customer'                   AS customer_name,
        CAST(NULL AS {{ t_string() }})       AS city,
        CAST(NULL AS DATE)                   AS registration_date,
        CAST(NULL AS {{ t_string() }})       AS customer_status,
        CAST(NULL AS {{ t_string() }})       AS customer_segment,
        CAST(NULL AS {{ t_string() }})       AS email,
        CAST(NULL AS {{ t_string() }})       AS phone_number,
        CAST(NULL AS DATE)                   AS birth_date,
        CAST(NULL AS {{ t_string() }})       AS occupation,
        CAST(NULL AS {{ t_string() }})       AS income_band,
        CAST(NULL AS {{ t_string() }})       AS kyc_status,
        TIMESTAMP '1900-01-01 00:00:00'      AS valid_from,
        CAST(NULL AS TIMESTAMP)              AS valid_to,
        TRUE                                 AS is_current,
        'UNKNOWN'                            AS dbt_scd_id
)

SELECT * FROM with_int_sk
UNION ALL
SELECT * FROM unknown
