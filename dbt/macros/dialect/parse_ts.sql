{# Parse a STRING column 'YYYY-MM-DD HH:MM:SS' into a TIMESTAMP. Returns NULL
   on bad input (BQ SAFE.PARSE_TIMESTAMP / DuckDB TRY_STRPTIME). #}
{% macro parse_ts(col) %}
    {%- if target.type == 'duckdb' -%}
        TRY_STRPTIME(CAST({{ col }} AS VARCHAR), '%Y-%m-%d %H:%M:%S')
    {%- else -%}
        SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', CAST({{ col }} AS STRING))
    {%- endif -%}
{% endmacro %}

{# Parse a STRING column 'YYYY-MM-DD' into a DATE. Returns NULL on bad input. #}
{% macro parse_date(col) %}
    {%- if target.type == 'duckdb' -%}
        TRY_STRPTIME(CAST({{ col }} AS VARCHAR), '%Y-%m-%d')::DATE
    {%- else -%}
        SAFE.PARSE_DATE('%Y-%m-%d', CAST({{ col }} AS STRING))
    {%- endif -%}
{% endmacro %}
