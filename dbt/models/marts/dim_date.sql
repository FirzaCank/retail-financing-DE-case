{# dim_date: one row per day, 2020-2030, plus the unknown member (-1). #}

{{ config(
    materialized = 'table',
    tags = ['marts', 'dim']
) }}

WITH spine AS (
    {{ date_spine('2020-01-01', '2030-12-31') }}
),

enriched AS (
    SELECT
        {{ date_to_int('date_value') }}                  AS date_sk,
        date_value                                       AS full_date,
        EXTRACT(YEAR    FROM date_value)                 AS year,
        EXTRACT(QUARTER FROM date_value)                 AS quarter,
        EXTRACT(MONTH   FROM date_value)                 AS month,
        EXTRACT(DAY     FROM date_value)                 AS day,
        {{ day_of_week('date_value') }}                  AS day_of_week,
        {{ day_of_week('date_value') }} IN (1, 7)        AS is_weekend
    FROM spine
),

unknown AS (
    SELECT
        {{ unknown_member_sk() }}        AS date_sk,
        CAST(NULL AS DATE)               AS full_date,
        CAST(NULL AS {{ t_int() }})      AS year,
        CAST(NULL AS {{ t_int() }})      AS quarter,
        CAST(NULL AS {{ t_int() }})      AS month,
        CAST(NULL AS {{ t_int() }})      AS day,
        CAST(NULL AS {{ t_int() }})      AS day_of_week,
        CAST(NULL AS {{ t_bool() }})     AS is_weekend
)

SELECT * FROM enriched
UNION ALL
SELECT * FROM unknown
