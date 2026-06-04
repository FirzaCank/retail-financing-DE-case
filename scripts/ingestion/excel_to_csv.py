#!/usr/bin/env python3
"""Split the source Excel workbook into one CSV per entity.

This is the first step of the landing pipeline. The workbook ships three
sheets (customers, transactions, branches); each is written to its own CSV
with no transformation so the raw layer mirrors the source exactly. All
cleaning happens later in dbt staging.

Design notes
------------
- Every column is read as a string (dtype=str, keep_default_na=False). The
  source mixes datetime and date strings in transaction_date / updated_at,
  and fraud_flag arrives as 'Y'/'N'. Reading as text prevents pandas from
  silently coercing those values (e.g. turning '0123' phone numbers into
  ints or 'Y'/'N' into NaN) before they reach BigQuery, where the raw DDL
  also keeps them as STRING.
- Empty cells are written as empty fields, not the literal "nan", so the
  downstream BigQuery load treats them as NULL.
- Sheet names are matched case-insensitively and trimmed, so a stray
  "Customers " heading still resolves.

Usage
-----
    python excel_to_csv.py \
        --input "../Data Engineer Analyst - Study Case.xlsx" \
        --output-dir data/
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

# Logical entity -> the CSV filename it lands in. The keys double as the
# expected sheet names (matched case-insensitively).
ENTITIES = ("customers", "transactions", "branches")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split the source Excel workbook into per-entity CSV files."
    )
    parser.add_argument(
        "--input",
        required=True,
        help="Path to the source .xlsx workbook.",
    )
    parser.add_argument(
        "--output-dir",
        default="data",
        help="Directory the CSV files are written to (default: data).",
    )
    return parser.parse_args(argv)


def resolve_sheet_map(available: list[str]) -> dict[str, str]:
    """Map each expected entity to the actual sheet name in the workbook.

    Matching is case-insensitive and whitespace-tolerant so the script does
    not break on cosmetic sheet renames. Raises if any entity is missing.
    """
    normalized = {name.strip().lower(): name for name in available}
    resolved: dict[str, str] = {}
    missing: list[str] = []
    for entity in ENTITIES:
        if entity in normalized:
            resolved[entity] = normalized[entity]
        else:
            missing.append(entity)
    if missing:
        raise ValueError(
            f"Workbook is missing required sheet(s): {missing}. "
            f"Found sheets: {available}"
        )
    return resolved


def convert(input_path: Path, output_dir: Path) -> dict[str, int]:
    """Read every required sheet and write it to CSV. Returns row counts."""
    if not input_path.is_file():
        raise FileNotFoundError(f"Input workbook not found: {input_path}")

    output_dir.mkdir(parents=True, exist_ok=True)

    workbook = pd.ExcelFile(input_path, engine="openpyxl")
    sheet_map = resolve_sheet_map(workbook.sheet_names)

    row_counts: dict[str, int] = {}
    for entity, sheet_name in sheet_map.items():
        # dtype=str + keep_default_na=False: read everything as raw text and
        # keep blanks as empty strings rather than NaN. na_filter=False is
        # implied by keep_default_na=False here.
        frame = workbook.parse(
            sheet_name,
            dtype=str,
            keep_default_na=False,
        )
        destination = output_dir / f"{entity}.csv"
        # index=False: no surrogate row index. na_rep="" keeps the (already
        # empty) blanks empty in the output.
        frame.to_csv(destination, index=False, na_rep="")
        row_counts[entity] = len(frame)
        print(
            f"[excel_to_csv] {entity}: {len(frame)} rows, "
            f"{len(frame.columns)} cols -> {destination}"
        )

    return row_counts


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        convert(Path(args.input), Path(args.output_dir))
    except (FileNotFoundError, ValueError) as exc:
        print(f"[excel_to_csv] ERROR: {exc}", file=sys.stderr)
        return 1
    print("[excel_to_csv] done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
