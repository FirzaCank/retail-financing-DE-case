#!/usr/bin/env python3
"""Freshness SLO check for the marts layer.

Measures how stale fact_transactions is and raises an alert when it breaches
the SLO. Designed to run as a scheduled Cloud Run job immediately after the
daily dbt build, or on a cron alongside it.

Core check
----------
    SELECT MAX(updated_at) FROM marts.fact_transactions
    lag_hours = now - MAX(updated_at)

    lag <= warning              -> OK        (exit 0)
    warning < lag <= critical   -> WARNING   (exit 1)
    lag > critical              -> CRITICAL  (exit 2)

Defaults: warning 24h, critical 48h.

Threshold model (reconciled with the SQL checks): the 24h warning line IS the
freshness SLO breach used by sql/monitoring/freshness_check.sql and
incident4_data_freshness.sql (their 'BREACH' tier). 48h critical is the
escalation tier for sustained staleness. The SQL checks add an 18h soft
pre-warning for dashboards; this pager-oriented job starts at the SLO line.

Two-signal classification (optional)
------------------------------------
A stale mart has two very different causes, and they page different teams.
Pass --run-results <path to dbt target/run_results.json> to disambiguate:

    Signal A: did the dbt build succeed? (parsed from run_results.json)
    Signal B: is the mart stale? (the freshness query above)

    A failed                  -> pipeline_failure  -> alert data engineering
    A success AND B stale      -> source_delay      -> alert operations
    A success AND B fresh      -> healthy

A pipeline failure is always treated as CRITICAL (exit 2) regardless of lag,
because the freshness number itself is then untrustworthy.

Output
------
A single JSON object is printed to stdout (Cloud Logging captures it as a
structured entry). With --push-metric the lag is also written to Cloud
Monitoring as custom.googleapis.com/pipeline/freshness_lag_hours.

Backends
--------
--backend bigquery (default) checks a BigQuery mart with ADC. --backend duckdb
checks a local DuckDB file (--duckdb path), so the same SLO logic runs in local
mode with no cloud account. --push-metric only applies to the bigquery backend.

Authentication (bigquery backend) uses Application Default Credentials.

Usage
-----
    python freshness_alert.py --project my-proj
    python freshness_alert.py --backend duckdb --duckdb dbt/retail_local.duckdb
    python freshness_alert.py --project my-proj --threshold-warning 12 \
        --threshold-critical 36 --run-results dbt/target/run_results.json \
        --push-metric
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

# Exit codes double as alert severities.
EXIT_OK = 0
EXIT_WARNING = 1
EXIT_CRITICAL = 2


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Freshness SLO check for marts.fact_transactions."
    )
    parser.add_argument(
        "--backend",
        choices=("bigquery", "duckdb"),
        default="bigquery",
        help="Where the mart lives (default: bigquery).",
    )
    parser.add_argument(
        "--project",
        default=None,
        help="GCP project id (required for --backend bigquery).",
    )
    parser.add_argument(
        "--duckdb",
        default="dbt/retail_local.duckdb",
        help="DuckDB file path (for --backend duckdb).",
    )
    parser.add_argument(
        "--dataset", default="marts", help="Marts dataset/schema (default: marts)."
    )
    parser.add_argument(
        "--table",
        default="fact_transactions",
        help="Fact table to check (default: fact_transactions).",
    )
    parser.add_argument(
        "--threshold-warning",
        type=float,
        default=24.0,
        help="Lag in hours that triggers WARNING (default: 24).",
    )
    parser.add_argument(
        "--threshold-critical",
        type=float,
        default=48.0,
        help="Lag in hours that triggers CRITICAL (default: 48).",
    )
    parser.add_argument(
        "--run-results",
        default=None,
        help="Optional path to dbt target/run_results.json for two-signal "
        "classification (source delay vs pipeline failure).",
    )
    parser.add_argument(
        "--push-metric",
        action="store_true",
        help="Write the lag to Cloud Monitoring as a custom metric.",
    )
    return parser.parse_args(argv)


def query_last_updated_bigquery(project: str, table_id: str) -> datetime | None:
    """MAX(updated_at) from a BigQuery mart. Lazy import keeps the GCP SDK
    optional for duckdb-only users."""
    from google.cloud import bigquery  # local import: optional dependency

    client = bigquery.Client(project=project)
    sql = f"SELECT MAX(updated_at) AS last_updated_at FROM `{table_id}`"
    row = list(client.query(sql).result())[0]
    return row["last_updated_at"]


def query_last_updated_duckdb(duckdb_path: str, dataset: str, table: str) -> datetime | None:
    """MAX(updated_at) from a local DuckDB mart."""
    import duckdb  # local import: optional dependency

    con = duckdb.connect(duckdb_path, read_only=True)
    try:
        return con.execute(
            f"SELECT MAX(updated_at) FROM {dataset}.{table}"
        ).fetchone()[0]
    finally:
        con.close()


def read_dbt_status(run_results_path: str) -> str:
    """Classify the last dbt build as 'success', 'failed', or 'unknown'.

    run_results.json holds one entry per node with a 'status' field; dbt uses
    'error'/'fail' for hard failures. Any such entry marks the build failed.
    """
    try:
        with open(run_results_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return "unknown"

    results = payload.get("results", [])
    if not results:
        return "unknown"
    failed = any(r.get("status") in ("error", "fail") for r in results)
    return "failed" if failed else "success"


def classify(lag_hours: float | None, warning: float, critical: float,
             dbt_status: str | None) -> tuple[str, str, str, int]:
    """Return (status, signal, alert_team, exit_code)."""
    # Pipeline failure dominates: the freshness number is unreliable.
    if dbt_status == "failed":
        return "CRITICAL", "pipeline_failure", "data_engineering", EXIT_CRITICAL

    # No data at all is a hard failure.
    if lag_hours is None:
        return "CRITICAL", "no_data", "data_engineering", EXIT_CRITICAL

    if lag_hours > critical:
        status, code = "CRITICAL", EXIT_CRITICAL
    elif lag_hours > warning:
        status, code = "WARNING", EXIT_WARNING
    else:
        status, code = "OK", EXIT_OK

    if status == "OK":
        signal, team = "healthy", "none"
    else:
        # Build succeeded (or status unknown) but the mart is stale: the delay
        # is upstream of the pipeline.
        signal = "source_delay"
        team = "operations"
    return status, signal, team, code


def push_metric(project: str, lag_hours: float) -> None:
    """Write the lag to Cloud Monitoring. Imported lazily so the dependency is
    only required when --push-metric is used."""
    from google.cloud import monitoring_v3  # local import: optional dependency

    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{project}"

    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/pipeline/freshness_lag_hours"
    series.resource.type = "global"
    series.resource.labels["project_id"] = project

    now = datetime.now(timezone.utc)
    point = monitoring_v3.Point(
        {
            "interval": {"end_time": {"seconds": int(now.timestamp())}},
            "value": {"double_value": float(lag_hours)},
        }
    )
    series.points = [point]
    client.create_time_series(name=project_name, time_series=[series])


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    now = datetime.now(timezone.utc)

    if args.backend == "bigquery":
        if not args.project:
            print("[freshness_alert] ERROR: --project is required for --backend bigquery",
                  file=sys.stderr)
            return EXIT_CRITICAL
        table_id = f"{args.project}.{args.dataset}.{args.table}"
    else:
        table_id = f"{args.duckdb}::{args.dataset}.{args.table}"

    try:
        if args.backend == "bigquery":
            last_updated = query_last_updated_bigquery(
                args.project, f"{args.project}.{args.dataset}.{args.table}"
            )
        else:
            last_updated = query_last_updated_duckdb(
                args.duckdb, args.dataset, args.table
            )
    except Exception as exc:  # noqa: BLE001 - surface any backend/auth error as CRITICAL
        report = {
            "checked_at": now.isoformat(),
            "table": table_id,
            "status": "CRITICAL",
            "signal": "check_error",
            "error": str(exc),
        }
        print(json.dumps(report))
        return EXIT_CRITICAL

    if last_updated is not None:
        # DuckDB may return a naive datetime; assume UTC to match the BQ path.
        if last_updated.tzinfo is None:
            last_updated = last_updated.replace(tzinfo=timezone.utc)
        lag_hours = (now - last_updated).total_seconds() / 3600.0
    else:
        lag_hours = None

    dbt_status = read_dbt_status(args.run_results) if args.run_results else None
    status, signal, team, code = classify(
        lag_hours, args.threshold_warning, args.threshold_critical, dbt_status
    )

    metric_pushed = False
    if args.push_metric and args.backend == "bigquery" and lag_hours is not None:
        try:
            push_metric(args.project, lag_hours)
            metric_pushed = True
        except Exception as exc:  # noqa: BLE001 - metric write must not mask the alert
            print(
                f"[freshness_alert] WARN: metric push failed: {exc}",
                file=sys.stderr,
            )

    report = {
        "checked_at": now.isoformat(),
        "table": table_id,
        "last_updated_at": last_updated.isoformat() if last_updated else None,
        "lag_hours": round(lag_hours, 2) if lag_hours is not None else None,
        "threshold_warning_hours": args.threshold_warning,
        "threshold_critical_hours": args.threshold_critical,
        "status": status,
        "signal": signal,
        "alert_team": team,
        "dbt_run_status": dbt_status,
        "metric_pushed": metric_pushed,
    }
    print(json.dumps(report))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
