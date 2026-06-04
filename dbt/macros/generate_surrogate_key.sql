{# ----------------------------------------------------------------------- #}
{# Macro: generate_sk                                                       #}
{# Purpose: Project-local wrapper around dbt_utils.generate_surrogate_key.  #}
{#          Centralizes the hashing approach so swapping algorithms         #}
{#          (e.g. MD5 to FARM_FINGERPRINT) is a one-file change.            #}
{# Usage:                                                                   #}
{#   {{ generate_sk(['customer_id', 'updated_at']) }}  -> hex MD5 string    #}
{# ----------------------------------------------------------------------- #}

{% macro generate_sk(field_list) %}
    {{ dbt_utils.generate_surrogate_key(field_list) }}
{% endmacro %}
