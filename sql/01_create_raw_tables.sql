-- 01_create_raw_tables.sql
-- Empty tables for the 8 Kaggle CSVs, loaded as-is (no cleaning here).
-- Everything raw lives in its own "raw" schema; cleaned views will go in "clean" later.
-- Column names are lowercase versions of the CSV headers.
-- CASCADE also drops my clean views that depend on these tables, so after reloading
-- I rerun sql/04_clean_views.sql to rebuild them.

CREATE SCHEMA IF NOT EXISTS raw;

-- One row = one product on one shopping trip
DROP TABLE IF EXISTS raw.transaction_data CASCADE;
CREATE TABLE raw.transaction_data (
    household_key      INTEGER,
    basket_id          BIGINT,
    day                INTEGER,
    product_id         BIGINT,
    quantity           INTEGER,
    sales_value        NUMERIC(10, 2),
    store_id           INTEGER,
    retail_disc        NUMERIC(10, 2),
    trans_time         INTEGER,          -- HHMM, e.g. 1631 = 4:31 pm
    week_no            INTEGER,
    coupon_disc        NUMERIC(10, 2),
    coupon_match_disc  NUMERIC(10, 2)
);

-- One row = one product
DROP TABLE IF EXISTS raw.product CASCADE;
CREATE TABLE raw.product (
    product_id            BIGINT,
    manufacturer          INTEGER,
    department            TEXT,
    brand                 TEXT,
    commodity_desc        TEXT,
    sub_commodity_desc    TEXT,
    curr_size_of_product  TEXT
);

-- One row = one household (only 801 of the 2,500 have this)
DROP TABLE IF EXISTS raw.hh_demographic CASCADE;
CREATE TABLE raw.hh_demographic (
    age_desc             TEXT,
    marital_status_code  TEXT,
    income_desc          TEXT,
    homeowner_desc       TEXT,
    hh_comp_desc         TEXT,
    household_size_desc  TEXT,           -- text because of values like '5+'
    kid_category_desc    TEXT,
    household_key        INTEGER
);

-- One row = one household targeted by one campaign
DROP TABLE IF EXISTS raw.campaign_table CASCADE;
CREATE TABLE raw.campaign_table (
    description    TEXT,                 -- TypeA / TypeB / TypeC
    household_key  INTEGER,
    campaign       INTEGER
);

-- One row = one campaign, with its start and end day
DROP TABLE IF EXISTS raw.campaign_desc CASCADE;
CREATE TABLE raw.campaign_desc (
    description  TEXT,
    campaign     INTEGER,
    start_day    INTEGER,
    end_day      INTEGER
);

-- One row = one product covered by one coupon in one campaign
DROP TABLE IF EXISTS raw.coupon CASCADE;
CREATE TABLE raw.coupon (
    coupon_upc  BIGINT,
    product_id  BIGINT,
    campaign    INTEGER
);

-- One row = one coupon redeemed by one household on one day
DROP TABLE IF EXISTS raw.coupon_redempt CASCADE;
CREATE TABLE raw.coupon_redempt (
    household_key  INTEGER,
    day            INTEGER,
    coupon_upc     BIGINT,
    campaign       INTEGER
);

-- One row = one product in one store in one week, with its display and mailer placement
DROP TABLE IF EXISTS raw.causal_data CASCADE;
CREATE TABLE raw.causal_data (
    product_id  BIGINT,
    store_id    INTEGER,
    week_no     INTEGER,
    display     TEXT,                    -- placement codes, '0' = not on display
    mailer      TEXT                     -- placement codes, '0' = not in the mailer
);
