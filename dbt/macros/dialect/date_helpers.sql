{# updated_at >= MAX(updated_at) - 3 days, for the incremental lookback. #}
{% macro lookback_ts(col, days) %}
    {%- if target.type == 'duckdb' -%}
        {{ col }} - INTERVAL '{{ days }} days'
    {%- else -%}
        TIMESTAMP_SUB({{ col }}, INTERVAL {{ days }} DAY)
    {%- endif -%}
{% endmacro %}

{# CURRENT_DATE() - N days. #}
{% macro date_minus_days(days) %}
    {%- if target.type == 'duckdb' -%}
        CURRENT_DATE - INTERVAL '{{ days }} days'
    {%- else -%}
        DATE_SUB(CURRENT_DATE(), INTERVAL {{ days }} DAY)
    {%- endif -%}
{% endmacro %}

{# Whole-day difference (end - start) as an integer. #}
{% macro day_diff(end_date, start_date) %}
    {%- if target.type == 'duckdb' -%}
        DATE_DIFF('day', {{ start_date }}, {{ end_date }})
    {%- else -%}
        DATE_DIFF({{ end_date }}, {{ start_date }}, DAY)
    {%- endif -%}
{% endmacro %}

{# date_sk as YYYYMMDD integer. #}
{% macro date_to_int(date_col) %}
    {%- if target.type == 'duckdb' -%}
        CAST(STRFTIME({{ date_col }}, '%Y%m%d') AS BIGINT)
    {%- else -%}
        CAST(FORMAT_DATE('%Y%m%d', {{ date_col }}) AS INT64)
    {%- endif -%}
{% endmacro %}
