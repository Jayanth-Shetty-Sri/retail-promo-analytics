-- 04_clean_views.sql
-- My clean layer. Everything I analyse from here on reads from the "clean" schema,
-- never straight from "raw". Each cleaning rule below matches a line in my cleaning log.
--
-- Run the WHOLE file in pgAdmin (open it, press F5 with nothing highlighted).
-- Takes a few minutes the first time because of the 36M-row promotions table.
-- Safe to rerun: it wipes the clean schema and rebuilds it.
--
-- A VIEW is a saved query - it reruns every time I use it, so it never takes up space.
-- A MATERIALIZED VIEW saves the result as a table - faster to query, but I have to
-- rebuild it (rerun this file) if the raw data changes. I use materialized views for
-- anything built on the big tables.

DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA clean;

-- Indexes on the raw tables so the joins below don't have to scan 36M rows every time
CREATE INDEX IF NOT EXISTS idx_tx_product_store_week ON raw.transaction_data (product_id, store_id, week_no);
CREATE INDEX IF NOT EXISTS idx_tx_basket            ON raw.transaction_data (basket_id);
CREATE INDEX IF NOT EXISTS idx_causal_key           ON raw.causal_data (product_id, store_id, week_no);


-- 1. TRANSACTIONS -------------------------------------------------------------
-- One row = one product bought on one trip, merchandise only.
-- Rules: drop fuel and non-product departments, drop lines where nothing was sold
-- or nothing was paid, turn discounts into positive dollar amounts (the 10 rows
-- with a positive retail_disc become 0).
CREATE VIEW clean.transactions AS
SELECT t.household_key,
       t.basket_id,
       t.day,
       t.week_no,
       t.trans_time,
       t.store_id,
       t.product_id,
       p.department,
       p.commodity_desc,
       p.sub_commodity_desc,
       p.brand,
       t.quantity,
       t.sales_value,
       -LEAST(t.retail_disc, 0)       AS retail_disc,
       -LEAST(t.coupon_disc, 0)       AS coupon_disc,
       -LEAST(t.coupon_match_disc, 0) AS coupon_match_disc
FROM raw.transaction_data t
JOIN raw.product p ON p.product_id = t.product_id
WHERE TRIM(COALESCE(p.department, '')) NOT IN ('', 'KIOSK-GAS', 'MISC SALES TRAN', 'MISC. TRANS.', 'COUP/STR & MFG')
  AND p.commodity_desc <> 'NO COMMODITY DESCRIPTION'
  AND t.quantity > 0
  AND t.sales_value > 0;


-- 2. PROMOTIONS ---------------------------------------------------------------
-- One row = one product in one store in one week.
-- Rule: 15,245 product-store-weeks have two different placement records. I keep one
-- row each; if either record says display or mailer, I count it as promoted.
-- (MAX on the code picks a real placement over '0'.)
CREATE MATERIALIZED VIEW clean.promotions AS
SELECT product_id,
       store_id,
       week_no,
       MAX(display)        AS display,
       MAX(mailer)         AS mailer,
       MAX(display) <> '0' AS on_display,
       MAX(mailer)  <> '0' AS in_mailer
FROM raw.causal_data
GROUP BY product_id, store_id, week_no;

CREATE UNIQUE INDEX ON clean.promotions (product_id, store_id, week_no);

-- The 115 stores that have promotion data at all
CREATE MATERIALIZED VIEW clean.promo_stores AS
SELECT DISTINCT store_id FROM clean.promotions;


-- 3. WEEKLY SALES BY PRODUCT AND STORE (the base for the uplift analysis) -------
-- One row = one product in one store in one week where it sold, with its promo flags.
-- promo_tracked = this store and week are covered by the promotion data
-- (115 stores, weeks 9-101). Uplift only uses rows where this is true.
CREATE MATERIALIZED VIEW clean.weekly_product_store_sales AS
SELECT t.product_id,
       t.store_id,
       t.week_no,
       t.department,
       t.commodity_desc,
       t.sub_commodity_desc,
       SUM(t.quantity)                                          AS units,
       SUM(t.sales_value)                                       AS sales,
       SUM(t.retail_disc + t.coupon_disc + t.coupon_match_disc) AS discount,
       COUNT(DISTINCT t.household_key)                          AS households,
       COALESCE(pr.on_display, FALSE)                           AS on_display,
       COALESCE(pr.in_mailer, FALSE)                            AS in_mailer,
       pr.display,
       pr.mailer,
       (ps.store_id IS NOT NULL AND t.week_no BETWEEN 9 AND 101) AS promo_tracked
FROM clean.transactions t
LEFT JOIN clean.promotions   pr ON pr.product_id = t.product_id AND pr.store_id = t.store_id AND pr.week_no = t.week_no
LEFT JOIN clean.promo_stores ps ON ps.store_id = t.store_id
GROUP BY t.product_id, t.store_id, t.week_no, t.department, t.commodity_desc, t.sub_commodity_desc,
         pr.on_display, pr.in_mailer, pr.display, pr.mailer, ps.store_id;

CREATE INDEX ON clean.weekly_product_store_sales (product_id, store_id, week_no);


-- 4. WEEKLY SALES BY CATEGORY ------------------------------------------------
-- One row = one category (commodity) in one week. Feeds the category page of the dashboard.
CREATE MATERIALIZED VIEW clean.weekly_category_sales AS
SELECT department,
       commodity_desc,
       week_no,
       SUM(sales_value)                                     AS sales,
       SUM(quantity)                                        AS units,
       SUM(retail_disc + coupon_disc + coupon_match_disc)   AS discount,
       COUNT(DISTINCT basket_id)                            AS baskets,
       COUNT(DISTINCT household_key)                        AS households
FROM clean.transactions
GROUP BY department, commodity_desc, week_no;


-- 5. BASKETS (one row per shopping trip) --------------------------------------
CREATE MATERIALIZED VIEW clean.baskets AS
SELECT basket_id,
       household_key,
       store_id,
       day,
       week_no,
       SUM(sales_value)                                     AS basket_value,
       SUM(quantity)                                        AS items,
       COUNT(*)                                             AS lines,
       SUM(retail_disc + coupon_disc + coupon_match_disc)   AS discount,
       BOOL_OR(coupon_disc > 0)                             AS used_coupon
FROM clean.transactions
GROUP BY basket_id, household_key, store_id, day, week_no;

CREATE INDEX ON clean.baskets (household_key);


-- 6. HOUSEHOLDS (one row per household) ---------------------------------------
-- Shopping summary + campaigns received + coupons redeemed + demographics where known.
CREATE MATERIALIZED VIEW clean.households AS
WITH shop AS (
    SELECT household_key,
           MIN(day)                         AS first_day,
           MAX(day)                         AS last_day,
           COUNT(*)                         AS trips,
           COUNT(DISTINCT week_no)          AS active_weeks,
           SUM(basket_value)                AS sales,
           AVG(basket_value)                AS avg_basket,
           SUM(discount)                    AS discount
    FROM clean.baskets
    GROUP BY household_key
),
camp AS (
    SELECT household_key, COUNT(*) AS campaigns_received
    FROM raw.campaign_table
    GROUP BY household_key
),
redeem AS (
    SELECT household_key, COUNT(*) AS coupons_redeemed
    FROM raw.coupon_redempt
    GROUP BY household_key
)
SELECT s.*,
       COALESCE(c.campaigns_received, 0) AS campaigns_received,
       COALESCE(r.coupons_redeemed, 0)   AS coupons_redeemed,
       (d.household_key IS NOT NULL)     AS has_demographics,
       d.age_desc,
       d.income_desc,
       d.marital_status_code,
       d.homeowner_desc,
       d.hh_comp_desc,
       d.household_size_desc,
       d.kid_category_desc
FROM shop s
LEFT JOIN camp   c ON c.household_key = s.household_key
LEFT JOIN redeem r ON r.household_key = s.household_key
LEFT JOIN raw.hh_demographic d ON d.household_key = s.household_key;


-- 7. COUPONS (duplicates removed) and CAMPAIGNS ---------------------------------
CREATE VIEW clean.coupons AS
SELECT DISTINCT coupon_upc, product_id, campaign
FROM raw.coupon;

CREATE VIEW clean.campaigns AS
SELECT d.campaign,
       d.description              AS campaign_type,
       d.start_day,
       d.end_day,
       d.end_day - d.start_day + 1 AS length_days,
       COUNT(t.household_key)     AS households_targeted
FROM raw.campaign_desc d
LEFT JOIN raw.campaign_table t ON t.campaign = d.campaign
GROUP BY d.campaign, d.description, d.start_day, d.end_day;


-- 8. CHECK: how much did cleaning remove? (this is the result pgAdmin shows) -----
SELECT '1. raw transactions'   AS layer, COUNT(*) AS rows, ROUND(SUM(sales_value)) AS sales,
       COUNT(DISTINCT basket_id) AS baskets, COUNT(DISTINCT household_key) AS households
FROM raw.transaction_data
UNION ALL
SELECT '2. clean transactions', COUNT(*), ROUND(SUM(sales_value)),
       COUNT(DISTINCT basket_id), COUNT(DISTINCT household_key)
FROM clean.transactions
UNION ALL
SELECT '3. clean baskets (rows should = baskets)', COUNT(*), ROUND(SUM(basket_value)),
       COUNT(DISTINCT basket_id), COUNT(DISTINCT household_key)
FROM clean.baskets
UNION ALL
SELECT '4. promotions: raw rows / clean rows / stores', (SELECT COUNT(*) FROM raw.causal_data), NULL,
       (SELECT COUNT(*) FROM clean.promotions), (SELECT COUNT(*) FROM clean.promo_stores)
UNION ALL
SELECT '5. coupons: raw rows / clean rows', (SELECT COUNT(*) FROM raw.coupon), NULL,
       (SELECT COUNT(*) FROM clean.coupons), NULL
ORDER BY layer;
