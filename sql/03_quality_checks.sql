-- 03_quality_checks.sql
-- I'm checking the raw tables for problems before building anything on top of them:
-- nulls, duplicates, negative values, outliers, odd days and products with no category.
-- Each result feeds a line in my cleaning log.
-- In pgAdmin: highlight ONE query and press F5.


-- QUERY 1: the overview. One row per check.
SELECT 'A1. transactions: rows with a NULL in any key column' AS check_name,
       (SELECT COUNT(*) FROM raw.transaction_data
         WHERE household_key IS NULL OR basket_id IS NULL OR product_id IS NULL
            OR store_id IS NULL OR day IS NULL OR week_no IS NULL OR sales_value IS NULL)::text AS result
UNION ALL
SELECT 'A2. product: rows with a blank or NULL department / commodity',
       (SELECT COUNT(*) FROM raw.product
         WHERE COALESCE(TRIM(department), '') = '' OR COALESCE(TRIM(commodity_desc), '') = '')::text
UNION ALL
SELECT 'A3. product: rows labelled NO COMMODITY DESCRIPTION',
       (SELECT COUNT(*) FROM raw.product WHERE commodity_desc = 'NO COMMODITY DESCRIPTION')::text
UNION ALL
SELECT 'B1. coupon: exact duplicate rows',
       (SELECT COUNT(*) - COUNT(DISTINCT (coupon_upc, product_id, campaign)) FROM raw.coupon)::text
UNION ALL
SELECT 'B2. coupon_redempt: exact duplicate rows',
       (SELECT COUNT(*) - COUNT(DISTINCT (household_key, day, coupon_upc, campaign)) FROM raw.coupon_redempt)::text
UNION ALL
SELECT 'C1. transactions: sales_value = 0 / sales_value < 0',
       (SELECT COUNT(*) FILTER (WHERE sales_value = 0) || ' / ' || COUNT(*) FILTER (WHERE sales_value < 0)
          FROM raw.transaction_data)
UNION ALL
SELECT 'C2. transactions: quantity = 0 / quantity < 0',
       (SELECT COUNT(*) FILTER (WHERE quantity = 0) || ' / ' || COUNT(*) FILTER (WHERE quantity < 0)
          FROM raw.transaction_data)
UNION ALL
SELECT 'C3. transactions: positive retail_disc / coupon_disc / coupon_match_disc',
       (SELECT COUNT(*) FILTER (WHERE retail_disc > 0) || ' / ' || COUNT(*) FILTER (WHERE coupon_disc > 0)
               || ' / ' || COUNT(*) FILTER (WHERE coupon_match_disc > 0)
          FROM raw.transaction_data)
UNION ALL
SELECT 'D1. transactions: quantity > 100 (rows) / max quantity',
       (SELECT COUNT(*) FILTER (WHERE quantity > 100) || ' / ' || MAX(quantity) FROM raw.transaction_data)
UNION ALL
SELECT 'D2. transactions: sales_value > 100 (rows) / max sales_value',
       (SELECT COUNT(*) FILTER (WHERE sales_value > 100) || ' / ' || MAX(sales_value) FROM raw.transaction_data)
UNION ALL
SELECT 'E1. weeks whose days span more than 7 days',
       (SELECT COUNT(*) FROM (SELECT week_no FROM raw.transaction_data
                               GROUP BY week_no HAVING MAX(day) - MIN(day) > 6) w)::text
UNION ALL
SELECT 'E2. transactions: trans_time not a real HHMM time',
       (SELECT COUNT(*) FROM raw.transaction_data
         WHERE trans_time < 0 OR trans_time > 2359 OR trans_time % 100 > 59)::text
UNION ALL
SELECT 'E3. redemptions outside their campaign''s start-end days',
       (SELECT COUNT(*) FROM raw.coupon_redempt r
          JOIN raw.campaign_desc c ON c.campaign = r.campaign
         WHERE r.day < c.start_day OR r.day > c.end_day)::text
UNION ALL
SELECT 'E4. campaigns where end_day is before start_day',
       (SELECT COUNT(*) FROM raw.campaign_desc WHERE end_day < start_day)::text;


-- QUERY 2: the 15,245 repeated rows in causal_data.
-- Are they exact copies (easy to drop) or the same product-store-week with
-- two different placements (needs a rule)? Takes 1-2 minutes.
SELECT COUNT(*) FILTER (WHERE n_rows > 1)                     AS keys_with_repeats,
       COUNT(*) FILTER (WHERE n_rows > 1 AND n_versions = 1)  AS exact_copies,
       COUNT(*) FILTER (WHERE n_versions > 1)                 AS conflicting_placements
FROM (
    SELECT product_id, store_id, week_no,
           COUNT(*)                          AS n_rows,
           COUNT(DISTINCT (display, mailer)) AS n_versions
    FROM raw.causal_data
    GROUP BY product_id, store_id, week_no
) k;


-- QUERY 3: sales by department. Shows non-grocery things (fuel, kiosk, misc)
-- and where the huge quantities and odd values sit.
SELECT p.department,
       COUNT(DISTINCT t.product_id)                     AS products,
       COUNT(*)                                         AS rows,
       ROUND(SUM(t.sales_value))                        AS sales,
       MAX(t.quantity)                                  AS max_quantity,
       COUNT(*) FILTER (WHERE t.sales_value <= 0)       AS zero_or_neg_sales_rows,
       COUNT(*) FILTER (WHERE t.retail_disc > 0)        AS positive_disc_rows
FROM raw.transaction_data t
JOIN raw.product p ON p.product_id = t.product_id
GROUP BY p.department
ORDER BY sales DESC;
