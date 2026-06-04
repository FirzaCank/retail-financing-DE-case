#!/usr/bin/env python3
"""Load the landing CSV files into a local DuckDB file's raw schema.

Local-mode counterpart to bq_load_raw.py. Instead of GCS plus BigQuery, this
reads data/*.csv straight into a DuckDB database file so the whole pipeline
can run on a laptop with no cloud account. The raw tables keep the same shape
as the BigQuery DDL (date/timestamp columns stay VARCHAR, amount is DECIMAL,
two metadata columns are stamped on every row):

    ingestion_ts  = load time
    source_file   = the local path the row came from

Idempotency: before loading an entity the script checks whether its
source_file is already present in the raw table and skips it if so, so
re-running for the same date is safe (same guarantee as the BigQuery loader).

Usage
-----
    python load_local_duckdb.py --source-dir data/ --duckdb retail_local.duckdb
    python load_local_duckdb.py --source-dir data/ --date 2026-06-04
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import duckdb

ENTITIES = ("customers", "transactions", "branches")

# Column types per raw table, mirroring sql/ddl/02_raw_tables.sql. Anything
# not listed is VARCHAR (dates/timestamps stay text and are cast in staging).
RAW_COLUMNS: dict[str, list[tuple[str, str]]] = {
    "transactions": [
        ("transaction_id", "VARCHAR"), ("customer_id", "VARCHAR"),
        ("branch_id", "VARCHAR"), ("transaction_date", "VARCHAR"),
        ("amount", "DECIMAL(18,4)"), ("payment_method", "VARCHAR"),
        ("transaction_status", "VARCHAR"), ("channel", "VARCHAR"),
        ("updated_at", "VARCHAR"), ("merchant_category", "VARCHAR"),
        ("device_type", "VARCHAR"), ("currency", "VARCHAR"),
        ("fraud_flag", "VARCHAR"), ("promo_code", "VARCHAR"),
    ],
    "customers": [
        ("customer_id", "VARCHAR"), ("customer_name", "VARCHAR"),
        ("city", "VARCHAR"), ("registration_date", "VARCHAR"),
        ("customer_status", "VARCHAR"), ("customer_segment", "VARCHAR"),
        ("email", "VARCHAR"), ("phone_number", "VARCHAR"),
        ("birth_date", "VARCHAR"), ("occupation", "VARCHAR"),
        ("income_band", "VARCHAR"), ("kyc_status", "VARCHAR"),
    ],
    "branches": [
        ("branch_id", "VARCHAR"), ("branch_name", "VARCHAR"),
        ("region", "VARCHAR"), ("branch_status", "VARCHAR"),
        ("branch_type", "VARCHAR"), ("opening_date", "VARCHAR"),
        ("manager_name", "VARCHAR"), ("city", "VARCHAR"),
    ],
}

META_COLUMNS = [("ingestion_ts", "TIMESTAMP"), ("source_file", "VARCHAR")]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Load landing CSV files into a local DuckDB raw schema."
    )
    parser.add_argument("--source-dir", default="data",
                        help="Directory holding the CSV files (default: data).")
    parser.add_argument("--duckdb", default="dbt/retail_local.duckdb",
                        help="Path to the DuckDB file (default: dbt/retail_local.duckdb).")
    parser.add_argument("--date", default=None,
                        help="Tag the source_file with this date YYYY-MM-DD. Default: today UTC.")
    return parser.parse_args(argv)


def resolve_date(raw: str | None) -> datetime:
    if raw is None:
        return datetime.now(timezone.utc)
    try:
        return datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise ValueError(f"--date must be YYYY-MM-DD, got '{raw}'") from exc


def ensure_raw_table(con: duckdb.DuckDBPyConnection, entity: str) -> None:
    """Create the raw schema and table if they do not exist yet."""
    cols = RAW_COLUMNS[entity] + META_COLUMNS
    col_ddl = ", ".join(f'"{name}" {dtype}' for name, dtype in cols)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")
    con.execute(f'CREATE TABLE IF NOT EXISTS raw.raw_{entity} ({col_ddl})')


def already_loaded(con: duckdb.DuckDBPyConnection, entity: str, source_file: str) -> bool:
    n = con.execute(
        f"SELECT COUNT(*) FROM raw.raw_{entity} WHERE source_file = ?",
        [source_file],
    ).fetchone()[0]
    return n > 0


def load_entity(con: duckdb.DuckDBPyConnection, source_dir: Path,
                entity: str, partition: datetime) -> str:
    csv_path = source_dir / f"{entity}.csv"
    if not csv_path.is_file():
        raise FileNotFoundError(f"CSV not found: {csv_path}")

    ensure_raw_table(con, entity)

    # source_file mirrors the gs:// path the BigQuery loader records, so the
    # marts see the same provenance string in either mode.
    source_file = f"local://{partition:%Y/%m/%d}/{entity}.csv"
    if already_loaded(con, entity, source_file):
        print(f"[load_local_duckdb] {entity}: SKIP, {source_file} already loaded.")
        return f"{entity}: skipped (already loaded)"

    src_cols = [name for name, _ in RAW_COLUMNS[entity]]
    select_cols = ", ".join(f'"{c}"' for c in src_cols)
    # read_csv with all VARCHAR so blanks become NULL and nothing is coerced.
    # Cast amount to DECIMAL on the way in to match the raw table type.
    cast_select = ", ".join(
        f'CAST("{name}" AS {dtype}) AS "{name}"' for name, dtype in RAW_COLUMNS[entity]
    )
    con.execute(
        f"""
        INSERT INTO raw.raw_{entity}
        SELECT {cast_select}, ? AS ingestion_ts, ? AS source_file
        FROM read_csv(?, header = true, all_varchar = true)
        """,
        [partition, source_file, str(csv_path)],
    )
    n = con.execute(f"SELECT COUNT(*) FROM raw.raw_{entity} WHERE source_file = ?",
                    [source_file]).fetchone()[0]
    print(f"[load_local_duckdb] {entity}: loaded {n} rows into raw.raw_{entity}.")
    return f"{entity}: loaded {n} rows"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        partition = resolve_date(args.date)
        source_dir = Path(args.source_dir)
        Path(args.duckdb).parent.mkdir(parents=True, exist_ok=True)
        con = duckdb.connect(args.duckdb)
        try:
            summary = [load_entity(con, source_dir, e, partition) for e in ENTITIES]
        finally:
            con.close()
    except (FileNotFoundError, ValueError) as exc:
        print(f"[load_local_duckdb] ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"[load_local_duckdb] done. DuckDB: {args.duckdb}")
    for line in summary:
        print(f"[load_local_duckdb]   {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
