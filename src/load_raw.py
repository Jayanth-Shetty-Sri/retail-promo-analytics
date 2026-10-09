"""
Loads the 8 Kaggle CSVs from data/raw/ into PostgreSQL.

Run from the repo's main folder:
    python src/load_raw.py

It asks for PostgreSQL password,
creates the empty tables from sql/01_create_raw_tables.sql, then copies each CSV in.
"""
import time
from getpass import getpass
from pathlib import Path

import psycopg2

RAW_DIR = Path("data/raw")
CREATE_TABLES_SQL = Path("sql/01_create_raw_tables.sql")

# smallest first, so if something's wrong it fails fast
TABLES = ["campaign_desc", "hh_demographic", "coupon_redempt", "campaign_table",
          "product", "coupon", "transaction_data", "causal_data"]

conn = psycopg2.connect(
    host="localhost",
    port=5432,
    dbname="retail_promo",
    user="postgres",
    password=getpass("PostgreSQL password: "),   # typing is hidden, that's normal
)
cur = conn.cursor()

print("Creating empty tables...")
cur.execute(CREATE_TABLES_SQL.read_text())
conn.commit()

for table in TABLES:
    start = time.time()
    with open(RAW_DIR / f"{table}.csv", encoding="utf-8-sig") as f:
        # read the CSV's header so the columns line up no matter what order they're in
        columns = f.readline().strip().lower()
        f.seek(0)
        # COPY is PostgreSQL's bulk-load command - much faster than inserting row by row
        cur.copy_expert(f"COPY raw.{table} ({columns}) FROM STDIN WITH (FORMAT csv, HEADER true)", f)
    conn.commit()

    cur.execute(f"SELECT COUNT(*) FROM raw.{table}")
    print(f"  {table:<17} {cur.fetchone()[0]:>12,} rows   ({time.time() - start:.0f}s)")

conn.close()
print("Done.")
