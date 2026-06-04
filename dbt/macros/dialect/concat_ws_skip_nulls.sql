{# Join a list of expressions with a separator, skipping NULLs, returning ''
   when all are NULL. BQ has no CONCAT_WS, so use ARRAY_TO_STRING over an
   array literal (which drops NULLs). DuckDB has CONCAT_WS (also drops NULLs).
   `items` is a list of SQL expression strings. #}
{% macro concat_ws_skip_nulls(sep, items) %}
    {%- if target.type == 'duckdb' -%}
        CONCAT_WS('{{ sep }}', {{ items | join(', ') }})
    {%- else -%}
        ARRAY_TO_STRING([{{ items | join(', ') }}], '{{ sep }}')
    {%- endif -%}
{% endmacro %}
