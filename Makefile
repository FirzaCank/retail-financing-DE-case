install:
	pip install -r requirements.txt && cd dbt && dbt deps

excel-to-csv:
	python scripts/ingestion/excel_to_csv.py

upload-gcs:
	python scripts/ingestion/load_to_gcs.py

load-raw:
	python scripts/ingestion/bq_load_raw.py

dbt-run:
	cd dbt && dbt run

dbt-test:
	cd dbt && dbt test

dbt-snapshot:
	cd dbt && dbt snapshot

dbt-build:
	cd dbt && dbt build

freshness:
	python scripts/monitoring/freshness_alert.py

# --- GCP (BigQuery) end-to-end ---
all: excel-to-csv upload-gcs load-raw dbt-snapshot dbt-build freshness

# --- Local (DuckDB) end-to-end, no cloud account ---
DUCKDB ?= dbt/retail_local.duckdb

load-local:
	python scripts/ingestion/load_local_duckdb.py --source-dir data/ --duckdb $(DUCKDB)

build-local:
	cd dbt && dbt seed --target local \
		&& dbt run --select staging --target local \
		&& dbt snapshot --target local \
		&& dbt build --target local

freshness-local:
	python scripts/monitoring/freshness_alert.py --backend duckdb --duckdb $(DUCKDB)

local: excel-to-csv load-local build-local freshness-local
