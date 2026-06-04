{# Portable type names. BQ: STRING / INT64 / NUMERIC / BOOL.
   DuckDB: VARCHAR / BIGINT / DECIMAL / BOOLEAN. #}
{% macro t_string() %}{% if target.type == 'duckdb' %}VARCHAR{% else %}STRING{% endif %}{% endmacro %}
{% macro t_int() %}{% if target.type == 'duckdb' %}BIGINT{% else %}INT64{% endif %}{% endmacro %}
{% macro t_numeric() %}{% if target.type == 'duckdb' %}DECIMAL(18,4){% else %}NUMERIC{% endif %}{% endmacro %}
{% macro t_bool() %}{% if target.type == 'duckdb' %}BOOLEAN{% else %}BOOL{% endif %}{% endmacro %}
