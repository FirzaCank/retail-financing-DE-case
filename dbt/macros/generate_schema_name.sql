{#
    File: generate_schema_name.sql
    Purpose: Map each model's +schema directly to a bare BigQuery dataset
             (staging, marts, quarantine, snapshots, seeds) instead of dbt's
             default <target_schema>_<custom_schema> concatenation.
    Layer: macro

    Rationale: datasets are created up front by sql/ddl/01_bq_datasets.sql with
    bare names and a pinned location (asia-southeast2). The default dbt naming
    would produce marts_staging, marts_marts, etc., which do not exist and would
    be auto-created in the wrong (default US) location. Returning the custom
    schema verbatim keeps dbt output aligned with the DDL-provisioned datasets.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
