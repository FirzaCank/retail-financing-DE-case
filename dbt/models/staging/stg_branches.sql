{# stg_branches: cast dates, normalize categoricals. Adds branch_name_city_mismatch
   flag (27 of 30 rows); both fields carried as-is, not corrected. #}

{{ config(
    materialized = 'view',
    tags = ['staging', 'branches']
) }}

WITH source AS (
    SELECT
        branch_id,
        branch_name,
        region,
        branch_status,
        branch_type,
        opening_date,
        manager_name,
        city,
        ingestion_ts,
        source_file
    FROM {{ source('raw', 'raw_branches') }}
),

typed AS (
    SELECT
        branch_id,
        branch_name,
        UPPER(region)         AS region,
        UPPER(branch_status)  AS branch_status,
        UPPER(branch_type)    AS branch_type,
        {{ parse_date('opening_date') }} AS opening_date,
        manager_name,
        city,
        ingestion_ts,
        source_file
    FROM source
)

SELECT
    branch_id,
    branch_name,
    region,
    branch_status,
    branch_type,
    opening_date,
    manager_name,
    city,
    (LOWER(branch_name) NOT LIKE CONCAT('%', LOWER(city), '%'))
        AS branch_name_city_mismatch,
    ingestion_ts,
    source_file
FROM typed
