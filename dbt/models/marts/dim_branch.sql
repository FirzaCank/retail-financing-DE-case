{# dim_branch: SCD1. INACTIVE branches carried, not filtered (13 of 30).
   Unknown member catches the 80 transactions with broken branch_id 'B999'. #}

{{ config(
    materialized = 'table',
    tags = ['marts', 'dim']
) }}

WITH src AS (
    SELECT * FROM {{ ref('stg_branches') }}
),

with_sk AS (
    SELECT
        {{ surrogate_int('branch_id') }} AS branch_sk,
        branch_id,
        branch_name,
        region,
        branch_status,
        branch_type,
        opening_date,
        manager_name,
        city,
        branch_name_city_mismatch
    FROM src
),

unknown AS (
    SELECT
        {{ unknown_member_sk() }}            AS branch_sk,
        '{{ unknown_member_nk() }}'          AS branch_id,
        'Unknown Branch'                     AS branch_name,
        CAST(NULL AS {{ t_string() }})       AS region,
        CAST(NULL AS {{ t_string() }})       AS branch_status,
        CAST(NULL AS {{ t_string() }})       AS branch_type,
        CAST(NULL AS DATE)                   AS opening_date,
        CAST(NULL AS {{ t_string() }})       AS manager_name,
        CAST(NULL AS {{ t_string() }})       AS city,
        CAST(NULL AS {{ t_bool() }})         AS branch_name_city_mismatch
)

SELECT * FROM with_sk
UNION ALL
SELECT * FROM unknown
