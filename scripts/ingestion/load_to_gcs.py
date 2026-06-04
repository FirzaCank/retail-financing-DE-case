#!/usr/bin/env python3
"""Upload the per-entity CSV files to the GCS landing zone.

Second step of the landing pipeline. Files are written to a date-partitioned,
immutable path so every day's drop is independently reproducible and the raw
BigQuery load can reference an exact source URI:

    gs://{bucket}/landing/{YYYY}/{MM}/{DD}/{entity}.csv

Design notes
------------
- The partition date defaults to today in UTC. It can be overridden with
  --date (YYYY-MM-DD) for backfills or to re-stamp a historical drop.
- Landing is immutable by convention. This uploader refuses to overwrite an
  existing object unless --overwrite is passed, so an accidental re-run does
  not clobber an audited file. (GCS object versioning on the bucket is the
  belt-and-suspenders backstop.)
- Authentication uses Application Default Credentials. No key files. Locally:
  `gcloud auth application-default login`; on Cloud Run the attached service
  account is picked up automatically.

Usage
-----
    python load_to_gcs.py --bucket my-landing-bucket --source-dir data/
    python load_to_gcs.py --bucket my-landing-bucket --source-dir data/ \
        --date 2026-06-04 --overwrite
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

from google.api_core import exceptions as gcp_exceptions
from google.cloud import storage

ENTITIES = ("customers", "transactions", "branches")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload per-entity CSV files to the GCS landing zone."
    )
    parser.add_argument(
        "--bucket",
        required=True,
        help="Target GCS bucket name (no gs:// prefix).",
    )
    parser.add_argument(
        "--source-dir",
        default="data",
        help="Local directory holding the CSV files (default: data).",
    )
    parser.add_argument(
        "--date",
        default=None,
        help="Partition date YYYY-MM-DD. Default: today (UTC).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Allow overwriting an existing landing object. Off by default "
        "to keep the landing zone immutable.",
    )
    return parser.parse_args(argv)


def resolve_date(raw: str | None) -> datetime:
    """Return the partition date. Validates --date when supplied."""
    if raw is None:
        return datetime.now(timezone.utc)
    try:
        return datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise ValueError(
            f"--date must be YYYY-MM-DD, got '{raw}'"
        ) from exc


def landing_path(partition: datetime, entity: str) -> str:
    """Build the object path: landing/YYYY/MM/DD/{entity}.csv."""
    return (
        f"landing/{partition:%Y/%m/%d}/{entity}.csv"
    )


def upload(
    bucket_name: str,
    source_dir: Path,
    partition: datetime,
    overwrite: bool,
) -> list[str]:
    """Upload each entity CSV. Returns the list of gs:// URIs written."""
    if not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    client = storage.Client()
    bucket = client.bucket(bucket_name)

    uploaded: list[str] = []
    for entity in ENTITIES:
        local_file = source_dir / f"{entity}.csv"
        if not local_file.is_file():
            raise FileNotFoundError(f"Expected CSV not found: {local_file}")

        object_path = landing_path(partition, entity)
        blob = bucket.blob(object_path)

        if blob.exists() and not overwrite:
            raise FileExistsError(
                f"gs://{bucket_name}/{object_path} already exists. "
                f"Landing is immutable; pass --overwrite to replace it."
            )

        # if_generation_match=0 makes the upload a create-only operation when
        # we are not overwriting: it fails server-side if the object appeared
        # between the exists() check and the upload (race-safe immutability).
        kwargs = {} if overwrite else {"if_generation_match": 0}
        blob.upload_from_filename(
            str(local_file),
            content_type="text/csv",
            **kwargs,
        )

        uri = f"gs://{bucket_name}/{object_path}"
        uploaded.append(uri)
        print(f"[load_to_gcs] uploaded {local_file} -> {uri}")

    return uploaded


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        partition = resolve_date(args.date)
        upload(
            bucket_name=args.bucket,
            source_dir=Path(args.source_dir),
            partition=partition,
            overwrite=args.overwrite,
        )
    except (FileNotFoundError, FileExistsError, ValueError) as exc:
        print(f"[load_to_gcs] ERROR: {exc}", file=sys.stderr)
        return 1
    except gcp_exceptions.PreconditionFailed as exc:
        # if_generation_match=0 tripped: object was created concurrently.
        print(
            f"[load_to_gcs] ERROR: object already exists (concurrent write): {exc}",
            file=sys.stderr,
        )
        return 1
    except gcp_exceptions.GoogleAPICallError as exc:
        print(f"[load_to_gcs] ERROR: GCS API call failed: {exc}", file=sys.stderr)
        return 1
    print(f"[load_to_gcs] done. Partition date: {partition:%Y-%m-%d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
