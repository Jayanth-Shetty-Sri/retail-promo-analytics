-- 02_profile_raw.sql
-- First look at the raw tables: how big they are, what one row means,
-- which columns are unique keys, and how well the tables join to each other.


-- QUERY 1: row count for every table
SELECT 'transaction_data' AS table_name, COUNT(*) AS row_count FROM raw.transaction_data
UNION ALL SELECT 'causal_data',    COUNT(*) FROM raw.causal_data
UNION ALL SELECT 'product',        COUNT(*) FROM raw.product
UNION ALL SELECT 'coupon',         COUNT(*) FROM raw.coupon
UNION ALL SELECT 'campaign_table', COUNT(*) FROM raw.campaign_table
UNION ALL SELECT 'coupon_redempt', COUNT(*) FROM raw.coupon_redempt
UNION ALL SELECT 'hh_demographic', COUNT(*) FROM raw.hh_demographic
UNION ALL SELECT 'campaign_desc',  COUNT(*) FROM raw.campaign_desc
ORDER BY row_count DESC;


-- QUERY 2: keys, coverage and joins
-- "x of y" means x distinct values out of y rows. If x = y, that column (or combo) is a unique key.
SELECT '1. product: distinct product_id of rows' AS check_name,
       (SELECT COUNT(DISTINCT product_id) || ' of ' || COUNT(*) FROM raw.product) AS result
UNION ALL
SELECT '2. hh_demographic: distinct household_key of rows',
       (SELECT COUNT(DISTINCT household_key) || ' of ' || COUNT(*) FROM raw.hh_demographic)
UNION ALL
SELECT '3. campaign_desc: distinct campaign of rows',
       (SELECT COUNT(DISTINCT campaign) || ' of ' || COUNT(*) FROM raw.campaign_desc)
UNION ALL
SELECT '4. campaign_table: distinct (household, campaign) of rows',
       (SELECT COUNT(DISTINCT (household_key, campaign)) || ' of ' || COUNT(*) FROM raw.campaign_table)
UNION ALL
SELECT '5. coupon: distinct (coupon_upc, product_id, campaign) of rows',
       (SELECT COUNT(DISTINCT (coupon_upc, product_id, campaign)) || ' of ' || COUNT(*) FROM raw.coupon)
UNION ALL
SELECT '6. transactions: distinct (basket, product) of rows',
       (SELECT COUNT(DISTINCT (basket_id, product_id)) || ' of ' || COUNT(*) FROM raw.transaction_data)
UNION ALL
SELECT '7. causal_data: distinct (product, store, week) of rows',
       (SELECT COUNT(DISTINCT (product_id, store_id, week_no)) || ' of ' || COUNT(*) FROM raw.causal_data)
UNION ALL
SELECT '8. transactions: day range / week range',
       (SELECT MIN(day) || '-' || MAX(day) || ' / ' || MIN(week_no) || '-' || MAX(week_no) FROM raw.transaction_data)
UNION ALL
SELECT '9. causal_data: week range',
       (SELECT MIN(week_no) || '-' || MAX(week_no) FROM raw.causal_data)
UNION ALL
SELECT '10. campaigns: first start day / last end day',
       (SELECT MIN(start_day) || ' / ' || MAX(end_day) FROM raw.campaign_desc)
UNION ALL
SELECT '11. stores: in causal_data / in transactions',
       (SELECT COUNT(DISTINCT store_id) FROM raw.causal_data) || ' / ' ||
       (SELECT COUNT(DISTINCT store_id) FROM raw.transaction_data)
UNION ALL
SELECT '12. households: transactions / demographics / campaigns',
       (SELECT COUNT(DISTINCT household_key) FROM raw.transaction_data) || ' / ' ||
       (SELECT COUNT(DISTINCT household_key) FROM raw.hh_demographic) || ' / ' ||
       (SELECT COUNT(DISTINCT household_key) FROM raw.campaign_table)
UNION ALL
SELECT '13. transaction rows whose product_id is missing from product',
       (SELECT COUNT(*)::text FROM raw.transaction_data t
         WHERE NOT EXISTS (SELECT 1 FROM raw.product p WHERE p.product_id = t.product_id))
UNION ALL
SELECT '14. redemptions whose coupon_upc is missing from coupon',
       (SELECT COUNT(*)::text FROM raw.coupon_redempt r
         WHERE NOT EXISTS (SELECT 1 FROM raw.coupon c WHERE c.coupon_upc = r.coupon_upc));
