-- 07_rfm.sql
-- Customer segments: RFM scores, segments and churn-risk flags for every household.
-- Run the WHOLE file in pgAdmin (F5, nothing highlighted). Takes under a minute.
--
-- RFM = Recency (days since the last trip), Frequency (number of trips),
--       Monetary (total spend). Each is scored 1-5 with NTILE: 5 = best fifth of households.
-- The data ends on day 711, so "today" is day 711.
--
-- Churn-risk flags:
--   gone_quiet = no trip for more than twice this household's own usual longest gap
--                (its 90th-percentile gap between trips), and at least 4 weeks.
--                A weekly shopper gets flagged much sooner than a monthly one.
--   fading     = spent less than half as much in the last 13 weeks as in the 13 weeks before.

DROP MATERIALIZED VIEW IF EXISTS analysis.household_rfm;
CREATE SCHEMA IF NOT EXISTS analysis;

CREATE MATERIALIZED VIEW analysis.household_rfm AS
WITH base AS (
    SELECT household_key,
           711 - MAX(day)    AS days_since_last,
           COUNT(*)          AS trips,
           SUM(basket_value) AS sales
    FROM clean.baskets
    GROUP BY household_key
),
-- gap in days between one shopping day and the next, for every household (LAG looks one row back)
gaps AS (
    SELECT household_key,
           day - LAG(day) OVER (PARTITION BY household_key ORDER BY day) AS gap
    FROM (SELECT DISTINCT household_key, day FROM clean.baskets) d
),
gap_stats AS (
    SELECT household_key,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap) AS median_gap,
           PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY gap) AS p90_gap
    FROM gaps
    WHERE gap IS NOT NULL
    GROUP BY household_key
),
recent AS (
    SELECT household_key,
           COALESCE(SUM(basket_value) FILTER (WHERE day > 711 - 91), 0)                     AS last_13w_sales,
           COALESCE(SUM(basket_value) FILTER (WHERE day > 711 - 182 AND day <= 711 - 91), 0) AS prev_13w_sales
    FROM clean.baskets
    GROUP BY household_key
),
scored AS (
    SELECT b.*,
           NTILE(5) OVER (ORDER BY days_since_last DESC) AS r_score,   -- longest ago = 1, most recent = 5
           NTILE(5) OVER (ORDER BY trips)                AS f_score,
           NTILE(5) OVER (ORDER BY sales)                AS m_score
    FROM base b
)
SELECT s.household_key,
       s.days_since_last,
       s.trips,
       ROUND(s.sales, 2)                    AS sales,
       s.r_score,
       s.f_score,
       s.m_score,
       CASE
           WHEN s.r_score >= 4 AND s.f_score >= 4 THEN 'Champions'
           WHEN s.r_score >= 3 AND s.f_score >= 3 THEN 'Loyal'
           WHEN s.r_score >= 4                    THEN 'Promising'
           WHEN s.r_score = 3                     THEN 'Needs attention'
           WHEN s.f_score >= 3                    THEN 'At risk'
           ELSE                                        'Lost'
       END                                  AS segment,
       g.median_gap,
       g.p90_gap,
       r.last_13w_sales,
       r.prev_13w_sales,
       s.days_since_last > GREATEST(2 * COALESCE(g.p90_gap, 14), 28)          AS gone_quiet,
       (r.prev_13w_sales > 0 AND r.last_13w_sales < 0.5 * r.prev_13w_sales)  AS fading
FROM scored s
LEFT JOIN gap_stats g ON g.household_key = s.household_key
LEFT JOIN recent    r ON r.household_key = s.household_key;

CREATE UNIQUE INDEX ON analysis.household_rfm (household_key);


-- Summary: one row per segment
SELECT segment,
       COUNT(*)                                                    AS households,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_households,
       ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 1)      AS pct_sales,
       ROUND(AVG(days_since_last))                                 AS avg_days_since_last,
       ROUND(AVG(trips))                                           AS avg_trips,
       ROUND(AVG(sales))                                           AS avg_sales,
       COUNT(*) FILTER (WHERE gone_quiet)                          AS gone_quiet,
       COUNT(*) FILTER (WHERE fading)                              AS fading
FROM analysis.household_rfm
GROUP BY segment
ORDER BY SUM(sales) DESC;
