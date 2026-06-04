{# Deterministic INT64/BIGINT surrogate from a single string expression.
   BQ uses FARM_FINGERPRINT; DuckDB has no equivalent, so we take the first
   15 hex digits of MD5 (60 bits) and parse to BIGINT. Stable across runs,
   collision risk negligible at this row count. #}
{% macro surrogate_int(str_expr) %}
    {%- if target.type == 'duckdb' -%}
        CAST(('0x' || SUBSTR(MD5(CAST({{ str_expr }} AS VARCHAR)), 1, 15)) AS BIGINT)
    {%- else -%}
        FARM_FINGERPRINT(CAST({{ str_expr }} AS STRING))
    {%- endif -%}
{% endmacro %}

{# Same as surrogate_int but over the whole row, for the dedup tie-breaker.
   BQ: FARM_FINGERPRINT(TO_JSON_STRING(t)). DuckDB: cast the row struct to
   text and MD5 it (DuckDB lets you cast a table alias to VARCHAR). #}
{% macro surrogate_int_row(row_alias) %}
    {%- if target.type == 'duckdb' -%}
        CAST(('0x' || SUBSTR(MD5(CAST({{ row_alias }} AS VARCHAR)), 1, 15)) AS BIGINT)
    {%- else -%}
        FARM_FINGERPRINT(TO_JSON_STRING({{ row_alias }}))
    {%- endif -%}
{% endmacro %}
