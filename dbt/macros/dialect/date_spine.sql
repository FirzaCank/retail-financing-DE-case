{# One row per calendar day between two literal dates, column aliased date_value.
   BQ: GENERATE_DATE_ARRAY + UNNEST. DuckDB: GENERATE_SERIES over dates. #}
{% macro date_spine(start_date, end_date) %}
    {%- if target.type == 'duckdb' -%}
        SELECT CAST(UNNEST(GENERATE_SERIES(DATE '{{ start_date }}', DATE '{{ end_date }}', INTERVAL '1 day')) AS DATE) AS date_value
    {%- else -%}
        SELECT date_value
        FROM UNNEST(GENERATE_DATE_ARRAY(DATE '{{ start_date }}', DATE '{{ end_date }}', INTERVAL 1 DAY)) AS date_value
    {%- endif -%}
{% endmacro %}

{# Day of week as 1=Sunday..7=Saturday, matching BQ EXTRACT(DAYOFWEEK).
   DuckDB DAYOFWEEK is 0=Sunday..6=Saturday, so shift by 1. #}
{% macro day_of_week(date_col) %}
    {%- if target.type == 'duckdb' -%}
        (DAYOFWEEK({{ date_col }}) + 1)
    {%- else -%}
        EXTRACT(DAYOFWEEK FROM {{ date_col }})
    {%- endif -%}
{% endmacro %}
