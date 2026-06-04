{# stg_customers: dedup on customer_id, cast dates. The source has 100
   duplicate customer_id pairs with conflicting email/phone/kyc; FARM_FINGERPRINT
   as a tiebreaker makes the surviving row deterministic when registration_date
   and ingestion_ts are identical across duplicates. #}

{{ config(
    materialized = 'view',
    tags = ['staging', 'customers']
) }}

WITH source AS (
    SELECT
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
        ingestion_ts,
        source_file
    FROM {{ source('raw', 'raw_customers') }}
),

typed AS (
    SELECT
        customer_id,
        customer_name,
        city,
        CAST({{ parse_ts('registration_date') }} AS DATE)  AS registration_date,
        UPPER(customer_status)   AS customer_status,
        UPPER(customer_segment)  AS customer_segment,
        email,
        phone_number,
        {{ parse_date('birth_date') }}                     AS birth_date,
        occupation,
        income_band,
        UPPER(kyc_status)        AS kyc_status,
        ingestion_ts,
        source_file
    FROM source
),

deduped AS (
    SELECT *
    FROM typed AS t
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY registration_date DESC NULLS LAST,
                 ingestion_ts      DESC,
                 {{ surrogate_int_row('t') }} DESC
    ) = 1
)

SELECT
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
    ingestion_ts,
    source_file
FROM deduped
