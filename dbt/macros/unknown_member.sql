{# ----------------------------------------------------------------------- #}
{# Macro: unknown_member_sk                                                 #}
{# Purpose: Returns the integer sentinel used across every dimension for    #}
{#          the unknown member row. Centralized so the value is the single  #}
{#          source of truth.                                                #}
{# Usage:                                                                   #}
{#   COALESCE(c.customer_sk, {{ unknown_member_sk() }})                     #}
{# Macro: unknown_member_nk                                                 #}
{# Purpose: Natural-key placeholder string used in unknown member rows.     #}
{# Usage:                                                                   #}
{#   SELECT {{ unknown_member_sk() }} AS customer_sk,                       #}
{#          '{{ unknown_member_nk() }}' AS customer_id, ...                 #}
{# ----------------------------------------------------------------------- #}

{% macro unknown_member_sk() %}-1{% endmacro %}

{% macro unknown_member_nk() %}UNKNOWN{% endmacro %}
