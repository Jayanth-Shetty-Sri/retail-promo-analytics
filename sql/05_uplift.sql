-- 05_uplift.sql
-- Promotion uplift: for every week a product was on display or in the mailer, how much
-- did it sell compared with a normal (non-promoted) week for that same product in that
-- same store? The difference is the extra (incremental) sales the promotion created.
--
-- Run the WHOLE file in pgAdmin (F5, nothing highlighted). Takes a few minutes.
-- The last query shows the summary I use for the findings.
--
-- My method, step by step:
--   1. Only the 115 stores and weeks 9-101 that have promotion data (93 weeks).
--   2. Seasonality: I divide each week's sales by a department-level seasonal index,
--      so a promo in a naturally busy week doesn't get credit for the season.
--   3. Baseline = a product-store's total sales in its NON-promoted weeks, divided by
--      the number of non-promoted weeks. Dividing by weeks (not by weeks with a sale)
--      matters: most weeks a product sells nothing to these 2,500 households, and
--      ignoring those zeros would make the baseline far too high.
--   4. Incremental sales in a promo week = actual sales - baseline.
--   5. Pull-forward: in the week right after a promotion ends, sales - baseline.
--      A negative number means people stocked up and bought less afterwards.

DROP SCHEMA IF EXISTS analysis CASCADE;
CREATE SCHEMA analysis;


-- 1. SEASONAL INDEX --------------------------------------------------------------
-- How busy each week is for each department, from ALL its sales in all stores.
-- 1.0 = an average week. I cap it between 0.5 and 2 so a tiny department with a
-- near-empty week can't blow the numbers up.
-- Why all sales and not just non-promoted sales: in a week with lots of promotions,
-- non-promoted products sell less (shoppers switch to the promoted ones), so an index
-- built from them would call that week "quiet" and inflate every promo week. Using all
-- sales errs the other way - a week that's busy because of promotions counts as a
-- busy week - so my uplift numbers are, if anything, a little on the low side.
CREATE MATERIALIZED VIEW analysis.season_index AS
WITH w AS (
    SELECT department, week_no, SUM(sales) AS sales
    FROM clean.weekly_product_store_sales
    WHERE week_no BETWEEN 9 AND 101
    GROUP BY department, week_no
)
SELECT department,
       week_no,
       LEAST(GREATEST(sales / AVG(sales) OVER (PARTITION BY department), 0.5), 2.0) AS season_idx
FROM w;


-- 2. WEEKLY SALES IN THE TRACKED STORES AND WEEKS, SEASON-ADJUSTED ----------------
CREATE MATERIALIZED VIEW analysis.ps_weeks AS
SELECT s.product_id,
       s.store_id,
       s.week_no,
       s.department,
       s.commodity_desc,
       s.sub_commodity_desc,
       s.sales,
       s.discount,
       s.sales / COALESCE(si.season_idx, 1) AS adj_sales,
       (s.on_display OR s.in_mailer)       AS promoted
FROM clean.weekly_product_store_sales s
LEFT JOIN analysis.season_index si ON si.department = s.department AND si.week_no = s.week_no
WHERE s.promo_tracked;

CREATE INDEX ON analysis.ps_weeks (product_id, store_id, week_no);


-- 3. WHICH PRODUCT-STORES I CAN MEASURE -------------------------------------------
-- I only measure products that sell regularly enough in that store: at least 8 weeks
-- with a sale out of the 93. I count promo AND normal weeks here on purpose - if I only
-- counted normal weeks, I'd be picking products that happened to sell well without
-- a promotion, which would make every promotion look worse than it is.
CREATE MATERIALIZED VIEW analysis.ps_candidates AS
SELECT product_id,
       store_id,
       MAX(department)         AS department,
       MAX(commodity_desc)     AS commodity_desc,
       MAX(sub_commodity_desc) AS sub_commodity_desc,
       SUM(adj_sales) FILTER (WHERE NOT promoted) AS nonpromo_sales
FROM analysis.ps_weeks
GROUP BY product_id, store_id
HAVING COUNT(*) >= 8;

CREATE UNIQUE INDEX ON analysis.ps_candidates (product_id, store_id);


-- 4. PROMO WEEKS for those product-stores (including weeks with zero sales) ---------
-- promo_type splits weeks into display only / mailer only / both, so I never count
-- the same week twice.
CREATE MATERIALIZED VIEW analysis.promo_weeks AS
SELECT p.product_id,
       p.store_id,
       p.week_no,
       p.display,
       p.mailer,
       CASE WHEN p.on_display AND p.in_mailer THEN 'display + mailer'
            WHEN p.on_display                 THEN 'display only'
            ELSE                                   'mailer only' END AS promo_type
FROM clean.promotions p
JOIN analysis.ps_candidates c ON c.product_id = p.product_id AND c.store_id = p.store_id
WHERE (p.on_display OR p.in_mailer)
  AND p.week_no BETWEEN 9 AND 101;

CREATE INDEX ON analysis.promo_weeks (product_id, store_id, week_no);


-- 5. BASELINE per product-store ---------------------------------------------------
CREATE MATERIALIZED VIEW analysis.baseline AS
SELECT c.product_id,
       c.store_id,
       c.department,
       c.commodity_desc,
       c.sub_commodity_desc,
       COUNT(pw.week_no)                                       AS promo_weeks,
       93 - COUNT(pw.week_no)                                  AS normal_weeks,
       COALESCE(c.nonpromo_sales, 0) / (93 - COUNT(pw.week_no)) AS baseline_weekly
FROM analysis.ps_candidates c
JOIN analysis.promo_weeks pw ON pw.product_id = c.product_id AND pw.store_id = c.store_id
GROUP BY c.product_id, c.store_id, c.department, c.commodity_desc, c.sub_commodity_desc, c.nonpromo_sales
HAVING 93 - COUNT(pw.week_no) >= 13;   -- need at least a quarter of normal weeks for a fair baseline


-- 6. UPLIFT FOR EVERY PROMO WEEK --------------------------------------------------
CREATE MATERIALIZED VIEW analysis.promo_week_uplift AS
SELECT pw.product_id,
       pw.store_id,
       pw.week_no,
       pw.promo_type,
       pw.display,
       pw.mailer,
       b.department,
       b.commodity_desc,
       b.sub_commodity_desc,
       COALESCE(s.adj_sales, 0)                     AS actual_sales,
       b.baseline_weekly,
       COALESCE(s.adj_sales, 0) - b.baseline_weekly AS incremental_sales,
       COALESCE(s.discount, 0)                      AS discount,
       -- the week after a promotion ends (next week not promoted, still inside week 101)
       CASE WHEN pw.week_no < 101 AND nxt_pw.product_id IS NULL
            THEN COALESCE(nxt.adj_sales, 0) - b.baseline_weekly END AS next_week_change
FROM analysis.promo_weeks pw
JOIN analysis.baseline b
  ON b.product_id = pw.product_id AND b.store_id = pw.store_id
LEFT JOIN analysis.ps_weeks s
  ON s.product_id = pw.product_id AND s.store_id = pw.store_id AND s.week_no = pw.week_no
LEFT JOIN analysis.promo_weeks nxt_pw
  ON nxt_pw.product_id = pw.product_id AND nxt_pw.store_id = pw.store_id AND nxt_pw.week_no = pw.week_no + 1
LEFT JOIN analysis.ps_weeks nxt
  ON nxt.product_id = pw.product_id AND nxt.store_id = pw.store_id AND nxt.week_no = pw.week_no + 1;


-- 7. SUMMARY: uplift by promotion type, then by display location and mailer placement --
-- avg_extra_per_week +/- ci95 is a rough 95% range for the average extra sales per promo week.
-- The range is built from product-store totals, not single weeks: weeks of the same
-- product in the same store share one baseline, so treating them as independent would
-- make the range look tighter than it really is.
-- net_extra_sales = extra sales during promos + the change in the week after (pull-forward).
CREATE VIEW analysis.uplift_summary AS
WITH tagged AS (
    SELECT '1. promo type' AS level, promo_type AS placement, u.* FROM analysis.promo_week_uplift u
    UNION ALL
    SELECT '2. display location (display-only weeks)', display, u.* FROM analysis.promo_week_uplift u
    WHERE promo_type = 'display only'
    UNION ALL
    SELECT '3. mailer placement (mailer-only weeks)', mailer, u.* FROM analysis.promo_week_uplift u
    WHERE promo_type = 'mailer only'
),
per_pair AS (
    SELECT level, placement, product_id, store_id,
           COUNT(*)               AS weeks,
           SUM(baseline_weekly)   AS baseline_sales,
           SUM(actual_sales)      AS actual_sales,
           SUM(incremental_sales) AS extra_sales,
           SUM(next_week_change)  AS after_change,
           SUM(discount)          AS discount
    FROM tagged
    GROUP BY level, placement, product_id, store_id
)
SELECT level,
       placement,
       SUM(weeks)                                                   AS promo_weeks,
       COUNT(*)                                                     AS product_stores,
       ROUND(SUM(baseline_sales))                                   AS baseline_sales,
       ROUND(SUM(actual_sales))                                     AS actual_sales,
       ROUND(SUM(extra_sales))                                      AS extra_sales,
       ROUND(100 * SUM(extra_sales) / NULLIF(SUM(baseline_sales), 0), 1) AS uplift_pct,
       ROUND(SUM(extra_sales) / SUM(weeks), 3)                      AS avg_extra_per_week,
       ROUND((1.96 * STDDEV_SAMP(extra_sales) * SQRT(COUNT(*)) / SUM(weeks))::numeric, 3) AS ci95,
       ROUND(SUM(after_change))                                     AS after_promo_change,
       ROUND(SUM(extra_sales) + COALESCE(SUM(after_change), 0))     AS net_extra_sales,
       ROUND(SUM(discount))                                         AS discount_given,
       ROUND(SUM(extra_sales) / NULLIF(SUM(discount), 0), 2)        AS extra_per_discount_dollar
FROM per_pair
GROUP BY level, placement;


-- What pgAdmin shows when the file finishes:
SELECT * FROM analysis.uplift_summary
ORDER BY level, extra_sales DESC;
