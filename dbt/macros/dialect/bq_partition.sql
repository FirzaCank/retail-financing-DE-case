{# partition_by spec for fact-style models. BQ only; DuckDB returns none so
   the config key is simply absent there. #}
{% macro fact_partition() %}
    {%- if target.type == 'bigquery' -%}
        {{ return({'field': 'transaction_ts', 'data_type': 'timestamp', 'granularity': 'day'}) }}
    {%- else -%}
        {{ return(none) }}
    {%- endif -%}
{% endmacro %}

{% macro fact_cluster() %}
    {%- if target.type == 'bigquery' -%}
        {{ return(['customer_sk', 'branch_sk']) }}
    {%- else -%}
        {{ return(none) }}
    {%- endif -%}
{% endmacro %}

{% macro quarantine_partition() %}
    {%- if target.type == 'bigquery' -%}
        {{ return({'field': 'rejected_at', 'data_type': 'timestamp', 'granularity': 'day'}) }}
    {%- else -%}
        {{ return(none) }}
    {%- endif -%}
{% endmacro %}
