{# Current timestamp. BQ wants CURRENT_TIMESTAMP(); DuckDB wants the keyword
   form CURRENT_TIMESTAMP (no parens). #}
{% macro now_ts() %}
    {%- if target.type == 'duckdb' -%}
        CURRENT_TIMESTAMP
    {%- else -%}
        CURRENT_TIMESTAMP()
    {%- endif -%}
{% endmacro %}
