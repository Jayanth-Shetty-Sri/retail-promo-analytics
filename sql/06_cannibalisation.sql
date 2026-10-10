-- 06_cannibalisation.sql
-- Is the extra sales from a promotion real growth, or did the promoted product just take
-- sales from similar products (same sub-category, same store, same week)?
--
--   promoted_extra  = how much more the promoted products sold than their own baseline
--   category_extra  = how much more the WHOLE sub-category sold than its normal week
--   taken_from_similar = promoted_extra - category_extra
--
-- If the sub-category grew by as much as the promoted items, nothing was cannibalised.
-- If it grew by less, the gap is sales the promotion took from similar products.
-- Uses the season-adjusted weekly sales from 05_uplift.sql, so run that first.
-- Run the WHOLE file (F5, nothing highlighted). Takes a few minutes.

DROP MATERIALIZED VIEW IF EXISTS analysis.ps_all_baseline CASCADE;


-- 1. A baseline for EVERY product-store that sold at least once (not just the ones
--    in the uplift table), because every promoted product counts here.
CREATE MATERIALIZED VIEW analysis.ps_all_baseline AS
WITH pairs AS (
    SELECT product_id,
           store_id,
           MAX(department)         AS department,
           MAX(sub_commodity_desc) AS sub_commodity_desc,
           COALESCE(SUM(adj_sales) FILTER (WHERE NOT promoted), 0) AS nonpromo_sales
    FROM analysis.ps_weeks
    GROUP BY product_id, store_id
),
promo_counts AS (
    SELECT p.product_id, p.store_id, COUNT(*) AS promo_weeks
    FROM clean.promotions p
    JOIN pairs ON pairs.product_id = p.product_id AND pairs.store_id = p.store_id
    WHERE (p.on_display OR p.in_mailer) AND p.week_no BETWEEN 9 AND 101
    GROUP BY p.product_id, p.store_id
)
SELECT pairs.*,
       COALESCE(pc.promo_weeks, 0) AS promo_weeks,
       pairs.nonpromo_sales / (93 - COALESCE(pc.promo_weeks, 0)) AS baseline_weekly
FROM pairs
LEFT JOIN promo_counts pc ON pc.product_id = pairs.product_id AND pc.store_id = pairs.store_id
WHERE COALESCE(pc.promo_weeks, 0) < 93;

CREATE UNIQUE INDEX ON analysis.ps_all_baseline (product_id, store_id);


-- 2. Extra sales of each promoted product in each promo week
CREATE MATERIALIZED VIEW analysis.promoted_product_weeks AS
SELECT p.product_id,
       p.store_id,
       p.week_no,
       b.department,
       b.sub_commodity_desc,
       CASE WHEN p.on_display AND p.in_mailer THEN 'display + mailer'
            WHEN p.on_display                 THEN 'display only'
            ELSE                                   'mailer only' END AS promo_type,
       COALESCE(s.adj_sales, 0) - b.baseline_weekly AS extra
FROM clean.promotions p
JOIN analysis.ps_all_baseline b ON b.product_id = p.product_id AND b.store_id = p.store_id
LEFT JOIN analysis.ps_weeks s
       ON s.product_id = p.product_id AND s.store_id = p.store_id AND s.week_no = p.week_no
WHERE (p.on_display OR p.in_mailer) AND p.week_no BETWEEN 9 AND 101;


-- 3. Sub-category totals per store-week, and which of those weeks had a promotion.
--    A sub-category is identified by department + name, because the same name
--    can appear in more than one department.
CREATE MATERIALIZED VIEW analysis.subcat_weeks AS
WITH totals AS (
    SELECT sub_commodity_desc, department, store_id, week_no, SUM(adj_sales) AS total_sales
    FROM analysis.ps_weeks
    GROUP BY sub_commodity_desc, department, store_id, week_no
),
promo AS (
    SELECT department, sub_commodity_desc, store_id, week_no,
           SUM(extra)      AS promoted_extra,
           COUNT(*)        AS promoted_products,
           CASE WHEN COUNT(DISTINCT promo_type) = 1 THEN MIN(promo_type) ELSE 'mixed' END AS promo_type
    FROM analysis.promoted_product_weeks
    GROUP BY department, sub_commodity_desc, store_id, week_no
)
SELECT COALESCE(t.department, p.department)                 AS department,
       COALESCE(t.sub_commodity_desc, p.sub_commodity_desc) AS sub_commodity_desc,
       COALESCE(t.store_id, p.store_id)                     AS store_id,
       COALESCE(t.week_no, p.week_no)                       AS week_no,
       COALESCE(t.total_sales, 0)                           AS total_sales,
       (p.week_no IS NOT NULL)                              AS promo_week,
       p.promoted_extra,
       p.promoted_products,
       p.promo_type
FROM totals t
FULL JOIN promo p
  ON p.department = t.department AND p.sub_commodity_desc = t.sub_commodity_desc
 AND p.store_id = t.store_id AND p.week_no = t.week_no;


-- 4. Sub-category baseline per store: its normal weekly sales in weeks with NO promotion
--    on any of its products. Needs at least 13 such weeks to be fair.
CREATE MATERIALIZED VIEW analysis.subcat_baseline AS
SELECT department,
       sub_commodity_desc,
       store_id,
       COUNT(*) FILTER (WHERE promo_week)                                AS promo_weeks,
       93 - COUNT(*) FILTER (WHERE promo_week)                           AS normal_weeks,
       SUM(total_sales) FILTER (WHERE NOT promo_week)
         / (93 - COUNT(*) FILTER (WHERE promo_week))                     AS baseline_weekly
FROM analysis.subcat_weeks
GROUP BY department, sub_commodity_desc, store_id
HAVING 93 - COUNT(*) FILTER (WHERE promo_week) >= 13;


-- 5. SUMMARY ------------------------------------------------------------------
-- taken_from_similar +/- taken_ci95 is a rough 95% range. Sub-category totals are big and
-- bounce around week to week, so this check is much noisier than the uplift itself:
-- if the range includes zero, I can't say whether the promotion took sales from similar
-- products or not.
-- coverage_pct = share of all promoted-product extra sales that this check could measure
-- (sub-categories promoted almost every week have no clean "normal" weeks, so they drop out).
CREATE VIEW analysis.cannibalisation_summary AS
WITH measured AS (
    SELECT w.department,
           w.sub_commodity_desc,
           w.store_id,
           w.promo_type,
           w.promoted_extra,
           w.total_sales - b.baseline_weekly AS category_extra
    FROM analysis.subcat_weeks w
    JOIN analysis.subcat_baseline b
      ON b.department = w.department AND b.sub_commodity_desc = w.sub_commodity_desc AND b.store_id = w.store_id
    WHERE w.promo_week
),
total_extra AS (SELECT SUM(extra) AS all_extra FROM analysis.promoted_product_weeks),
tagged AS (
    SELECT '1. overall' AS level, 'all promotions' AS grp, m.* FROM measured m
    UNION ALL
    SELECT '2. promo type', promo_type, m.* FROM measured m
    UNION ALL
    SELECT '3. department', department, m.* FROM measured m
),
-- add up each sub-category-store first: its weeks share one baseline, so they aren't
-- independent, and the range has to be built from these totals, not from single weeks
per_pair AS (
    SELECT level, grp, department, sub_commodity_desc, store_id,
           COUNT(*)            AS weeks,
           SUM(promoted_extra) AS promoted_extra,
           SUM(category_extra) AS category_extra
    FROM tagged
    GROUP BY level, grp, department, sub_commodity_desc, store_id
)
SELECT level,
       grp,
       SUM(weeks)                                       AS subcat_store_weeks,
       COUNT(*)                                         AS subcat_stores,
       ROUND(SUM(promoted_extra))                       AS promoted_extra,
       ROUND(SUM(category_extra))                       AS category_extra,
       ROUND(SUM(promoted_extra) - SUM(category_extra)) AS taken_from_similar,
       ROUND((1.96 * STDDEV_SAMP(promoted_extra - category_extra) * SQRT(COUNT(*)))::numeric)
                                                        AS taken_ci95,
       ROUND(100 * (SUM(promoted_extra) - SUM(category_extra)) / NULLIF(SUM(promoted_extra), 0), 1)
                                                        AS cannibalised_pct,
       CASE WHEN level = '1. overall'
            THEN ROUND(100 * SUM(promoted_extra) / (SELECT all_extra FROM total_extra), 1) END
                                                        AS coverage_pct
FROM per_pair
GROUP BY level, grp;


SELECT * FROM analysis.cannibalisation_summary
WHERE level <> '3. department' OR subcat_stores >= 30
ORDER BY level, promoted_extra DESC;
