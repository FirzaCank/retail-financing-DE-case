# Retail Financing Data Platform

Data Engineer study case. A daily export (customers, transactions, branches) lands in cloud storage, is ingested to BigQuery, and transformed with dbt into a star schema. Covers data quality quarantine, freshness monitoring, scalability, and four production incident investigations.

Stack: GCS + BigQuery + dbt + Python on GCP. The dbt models are also dialect-aware so the pipeline can be run locally on DuckDB to verify it without a GCP account (see [Run locally](#run-locally-duckdb) at the end).

---

## Architecture

![architecture](docs/images/architecture.png)

Layers: GCS landing (immutable daily CSV) → raw (append-only, schema mirror) → staging (dedup, cast, DQ flag) → marts (fact + dims). Bad rows go to quarantine, not dropped.

Full ERD: `docs/Phase2_Architecture_ERD.drawio`.

---

## Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cd dbt && dbt deps && cd ..
```

Copy `dbt/profiles.yml.example` to `~/.dbt/profiles.yml`.

---

## Run on GCP

Needs a GCP project (BigQuery + Cloud Storage enabled) and ADC. The GCS bucket must be in the same region as the datasets.

```bash
gcloud auth application-default login
export DBT_PROJECT_ID=<project>
export GCS_BUCKET=<bucket>

# Datasets + raw tables (once per env)
for f in sql/ddl/01_bq_datasets.sql sql/ddl/02_raw_tables.sql; do
  sed "s/PROJECT_ID/$DBT_PROJECT_ID/g" "$f" | bq query --use_legacy_sql=false --location=asia-southeast2
done

python scripts/ingestion/excel_to_csv.py --input "<file>.xlsx" --output-dir data/
python scripts/ingestion/load_to_gcs.py  --bucket $GCS_BUCKET --source-dir data/
python scripts/ingestion/bq_load_raw.py  --project $DBT_PROJECT_ID --bucket $GCS_BUCKET
cd dbt && dbt seed && dbt run --select staging && dbt snapshot && dbt build && cd ..
python scripts/monitoring/freshness_alert.py --project $DBT_PROJECT_ID
```

Ingestion scripts accept `--date YYYY-MM-DD` (default today UTC) and are idempotent. `dbt build` finishes at PASS 82 / ERROR 0 with a 12,000-row fact table.

---

## Warehouse design

Kimball star. `fact_transactions` is incremental MERGE with a 3-day lookback (source late-arrival lag up to 2 days). On BigQuery it is partitioned by `DATE(transaction_ts)` and clustered by `customer_sk` / `branch_sk`; the local DuckDB target skips those (not applicable). All dim joins are LEFT JOIN; broken FKs resolve to unknown member (`_sk = -1`).

`dim_customer` is SCD2 via dbt snapshot. `dim_branch` is SCD1. `dim_exchange_rate` is a seed with monthly USD/IDR rates (placeholders; the source has no FX column).

---

## Data quality

Hard-fail rows are flagged in staging (`dq_reason`), kept in the fact (`is_quarantined = TRUE`), and mirrored to `quarantine.transactions_rejected`. Rules: null amount, negative amount, future date, broken FK (C99999/B999), SUCCESS+negative conflict. Inactive customers/branches are carried, not filtered.

71 dbt tests cover PK uniqueness, FK integrity, and categorical values. Four custom singular tests assert business invariants (quarantine consistency, row count range, no future dates, no negatives).

---

## Monitoring

`freshness_alert.py` checks `MAX(updated_at)` vs now, exits 0/1/2 (OK/warn/critical). Tiers: WARN 18h, BREACH 24h, CRITICAL 48h. Add `--push-metric` to write to Cloud Monitoring.

SQL equivalents in `sql/monitoring/`: freshness check, per-day row count baseline, quarantine rate by reason. Charts in `notebooks/02_pipeline_monitoring.ipynb`.

---

## Incident investigations

`sql/investigation/` has four files, each with reproduction queries, root cause, fix, and verification against the live warehouse.

- **Incident 1 (incremental load):** late arrivals up to 2 days + duplicate-on-retry. Fix: MERGE on `transaction_id` + 3-day lookback.
- **Incident 2 (join duplication):** INNER JOIN fans 12,300 rows to 12,329 (+189 from dup customer_id, -80+−80 silently dropped). Fix: dedup in staging + LEFT JOIN + unknown member.
- **Incident 3 (schema evolution):** new source column broke rigid load. Fix: additive raw load (ALTER ADD COLUMN) + staging contract that selects explicit columns.
- **Incident 4 (freshness):** stale marts, no way to tell source delay vs pipeline failure. Fix: two-signal logic (mart MAX(updated_at) vs last Cloud Run success).

---

## Scalability notes

At 20M+ rows/day: partition pruning handles the scan cost, incremental MERGE keeps each run scoped to recent data. Split ingestion jobs per table when one slow source starts blocking others. Move to Cloud Composer when DAG complexity justifies it. Spark only if logic becomes non-SQL-expressible or sustained volume exceeds ~100M rows/day. Backfill = date-bounded re-run; GCS landing files are immutable.

---

## Run locally (DuckDB)

GCP is the target platform. To review the pipeline end-to-end without a cloud account, the same dbt models also run on DuckDB: BQ-specific functions (`FARM_FINGERPRINT`, `SAFE.PARSE_TIMESTAMP`, `GENERATE_DATE_ARRAY`, partition/cluster) are wrapped in `dbt/macros/dialect/` macros that switch on `target.type`. GCS and BigQuery are replaced by a local CSV load into one `.duckdb` file; partition/cluster are no-ops there.

```bash
make local
```

Produces the same star schema and the same row counts (fact 12,000, `dbt build` PASS 82 / ERROR 0). Future-dated quarantine counts differ by run date, which is expected (the rule is `> CURRENT_DATE`).
