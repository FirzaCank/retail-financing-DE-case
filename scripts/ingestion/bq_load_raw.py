#!/usr/bin/env python3
"""Load the landing CSV files from GCS into the BigQuery raw dataset.

Third step of the landing pipeline. Each daily CSV is appended (never
overwritten) to its raw table with two ingestion-metadata columns stamped on
every row:

    ingestion_ts  = load time (CURRENT_TIMESTAMP)
    source_file   = the exact gs:// URI the row was loaded from

Why a temp table + INSERT ... SELECT
------------------------------------
A BigQuery load job is free (no slot cost) but cannot inject literal columns
(ingestion_ts, source_file) that are absent from the file. So the file is
first loaded into a throwaway _load_tmp_* table (free load job), then a small
INSERT ... SELECT stamps the two metadata columns and writes into the
append-only raw table. The INSERT is a trivial query; the bulk data movement
stays on the free load path.

Schema handling
---------------
The raw tables are created up front by sql/ddl/02_raw_tables.sql (date and
timestamp columns are STRING; amount is NUMERIC; fraud_flag is STRING). This
loader reads the CSV header from GCS to learn the column order, then builds a
positional schema for the load (CSV loads match by position, not name, so the
order must follow the file). Types come from an explicit map; unknown columns
default to STRING, which is the permissive-load posture that keeps a new
source column from failing the whole batch (it lands as STRING and is dealt
with in staging).

Idempotency
-----------
Before loading an entity the script checks whether its source_file URI is
already present in the raw table. If so the file is skipped, so re-running the
job for the same date is safe (resolves the duplicate-after-retry failure
mode from Incident 1).

Authentication uses Application Default Credentials (no key files).

Usage
-----
    python bq_load_raw.py --project my-proj --bucket my-landing-bucket
    python bq_load_raw.py --project my-proj --bucket my-landing-bucket \
        --dataset raw --date 2026-06-04
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from google.api_core import exceptions as gcp_exceptions
from google.cloud import bigquery, storage

ENTITIES = ("customers", "transactions", "branches")

# Explicit column types per entity. Anything not listed defaults to STRING.
# This mirrors sql/ddl/02_raw_tables.sql: dates/timestamps stay STRING and are
# cast in staging; amount is NUMERIC; fraud_flag is STRING.
TYPE_OVERRIDES: dict[str, dict[str, str]] = {
    "transactions": {"amount": "NUMERIC"},
    "customers": {},
    "branches": {},
}

# Metadata columns appended to every raw table (not present in the CSV).
META_COLUMNS = ("ingestion_ts", "source_file")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Load landing CSV files from GCS into the BigQuery raw dataset."
    )
    parser.add_argument("--project", required=True, help="GCP project id.")
    parser.add_argument(
        "--dataset",
        default="raw",
        help="Target BigQuery dataset (default: raw).",
    )
    parser.add_argument(
        "--bucket",
        required=True,
        help="GCS landing bucket name (no gs:// prefix).",
    )
    parser.add_argument(
        "--date",
        default=None,
        help="Partition date YYYY-MM-DD of the landing drop. Default: today (UTC).",
    )
    return parser.parse_args(argv)


def resolve_date(raw: str | None) -> datetime:
    if raw is None:
        return datetime.now(timezone.utc)
    try:
        return datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise ValueError(f"--date must be YYYY-MM-DD, got '{raw}'") from exc


def gcs_uri(bucket: str, partition: datetime, entity: str) -> str:
    return f"gs://{bucket}/landing/{partition:%Y/%m/%d}/{entity}.csv"


def read_header(storage_client: storage.Client, bucket: str, partition: datetime,
                entity: str) -> list[str]:
    """Read the CSV header line from GCS to recover column order.

    Only the first chunk of the object is fetched; the header always fits in
    a few hundred bytes for these tables.
    """
    object_path = f"landing/{partition:%Y/%m/%d}/{entity}.csv"
    blob = storage_client.bucket(bucket).blob(object_path)
    if not blob.exists():
        raise FileNotFoundError(f"gs://{bucket}/{object_path} not found.")
    head = blob.download_as_bytes(start=0, end=16383).decode("utf-8")
    first_line = head.splitlines()[0]
    return [col.strip() for col in first_line.split(",")]


def build_schema(entity: str, header: list[str]) -> list[bigquery.SchemaField]:
    """Positional schema for the load, in the CSV's own column order."""
    overrides = TYPE_OVERRIDES[entity]
    return [
        bigquery.SchemaField(col, overrides.get(col, "STRING"))
        for col in header
    ]


def raw_table_ref(project: str, dataset: str, entity: str) -> str:
    return f"{project}.{dataset}.raw_{entity}"


def ensure_raw_table(client: bigquery.Client, table_id: str) -> None:
    """Confirm the append-only target exists (created by the raw DDL)."""
    try:
        client.get_table(table_id)
    except gcp_exceptions.NotFound as exc:
        raise RuntimeError(
            f"Raw table {table_id} does not exist. Run "
            f"sql/ddl/02_raw_tables.sql first."
        ) from exc


def already_loaded(client: bigquery.Client, table_id: str, uri: str) -> bool:
    """True if any row from this source_file is already in the raw table."""
    query = f"""
        SELECT COUNT(*) AS n
        FROM `{table_id}`
        WHERE source_file = @uri
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("uri", "STRING", uri)]
    )
    result = list(client.query(query, job_config=job_config).result())
    return result[0]["n"] > 0


def load_entity(
    bq_client: bigquery.Client,
    storage_client: storage.Client,
    project: str,
    dataset: str,
    bucket: str,
    partition: datetime,
    entity: str,
) -> str:
    """Load one entity. Returns a short status string for the run summary."""
    uri = gcs_uri(bucket, partition, entity)
    table_id = raw_table_ref(project, dataset, entity)

    ensure_raw_table(bq_client, table_id)

    if already_loaded(bq_client, table_id, uri):
        print(f"[bq_load_raw] {entity}: SKIP, {uri} already loaded.")
        return f"{entity}: skipped (already loaded)"

    header = read_header(storage_client, bucket, partition, entity)
    schema = build_schema(entity, header)

    # 1) Free load job into a throwaway temp table (WRITE_TRUNCATE so reruns
    #    after a mid-job failure are clean).
    tmp_table_id = f"{project}.{dataset}._load_tmp_{entity}_{partition:%Y%m%d}"
    load_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        allow_quoted_newlines=True,
    )
    load_job = bq_client.load_table_from_uri(
        uri, tmp_table_id, job_config=load_config
    )
    load_job.result()  # wait; raises on failure
    loaded_rows = bq_client.get_table(tmp_table_id).num_rows
    print(f"[bq_load_raw] {entity}: loaded {loaded_rows} rows into temp table.")

    # 1b) Schema-evolution tolerance (Incident 3). If the source file carries
    #     new columns the raw table does not have yet, add them as STRING so
    #     an additive source change does not break the load. The new columns
    #     land in raw and are surfaced by incident3_schema_evolution.sql Q1
    #     for review; staging keeps its explicit contract and ignores them
    #     until they are promoted. This is ALLOW_FIELD_ADDITION done
    #     explicitly, which keeps the per-row metadata stamping below intact.
    raw_schema_cols = {f.name for f in bq_client.get_table(table_id).schema}
    new_cols = [c for c in header if c not in raw_schema_cols]
    if new_cols:
        add_clauses = ", ".join(f"ADD COLUMN IF NOT EXISTS `{c}` STRING" for c in new_cols)
        bq_client.query(f"ALTER TABLE `{table_id}` {add_clauses}").result()
        print(f"[bq_load_raw] {entity}: schema drift, added new column(s) to raw: {new_cols}")

    # 2) Stamp metadata and append into the raw table. Column lists are
    #    explicit so order is independent of the file layout.
    col_csv = ", ".join(header)
    insert_sql = f"""
        INSERT INTO `{table_id}` ({col_csv}, {", ".join(META_COLUMNS)})
        SELECT {col_csv}, CURRENT_TIMESTAMP() AS ingestion_ts, @uri AS source_file
        FROM `{tmp_table_id}`
    """
    insert_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("uri", "STRING", uri)]
    )
    try:
        insert_job = bq_client.query(insert_sql, job_config=insert_config)
        insert_job.result()
        appended = insert_job.num_dml_affected_rows
        print(f"[bq_load_raw] {entity}: appended {appended} rows into {table_id}.")
    finally:
        # 3) Always drop the temp table, even if the INSERT failed.
        bq_client.delete_table(tmp_table_id, not_found_ok=True)

    return f"{entity}: loaded {appended} rows"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        partition = resolve_date(args.date)
        bq_client = bigquery.Client(project=args.project)
        storage_client = storage.Client(project=args.project)

        summary: list[str] = []
        for entity in ENTITIES:
            summary.append(
                load_entity(
                    bq_client=bq_client,
                    storage_client=storage_client,
                    project=args.project,
                    dataset=args.dataset,
                    bucket=args.bucket,
                    partition=partition,
                    entity=entity,
                )
            )
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"[bq_load_raw] ERROR: {exc}", file=sys.stderr)
        return 1
    except gcp_exceptions.GoogleAPICallError as exc:
        print(f"[bq_load_raw] ERROR: BigQuery/GCS API call failed: {exc}", file=sys.stderr)
        return 1

    print(f"[bq_load_raw] done. Partition date: {partition:%Y-%m-%d}")
    for line in summary:
        print(f"[bq_load_raw]   {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
