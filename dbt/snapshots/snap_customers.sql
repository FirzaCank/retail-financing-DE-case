{# snap_customers: SCD2 on the six fields that conflict within duplicate
   customer_id pairs (email, phone, birth_date, occupation, income_band,
   kyc_status). customer_name/city/status/segment never conflict so they
   are left out of check_cols and overwrite silently. #}

{% snapshot snap_customers %}

{{ config(
    target_schema = 'snapshots',
    unique_key    = 'customer_id',
    strategy      = 'check',
    check_cols    = ['email', 'phone_number', 'birth_date', 'occupation', 'income_band', 'kyc_status'],
    invalidate_hard_deletes = true
) }}

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
    kyc_status
FROM {{ ref('stg_customers') }}

{% endsnapshot %}
