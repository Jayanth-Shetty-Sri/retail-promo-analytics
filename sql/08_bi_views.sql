-- 08_bi_views.sql
-- Small, tidy views for the Power BI dashboard, all in one "bi" schema.
-- Power BI imports only these, never the big raw tables.
-- Run the WHOLE file in pgAdmin (F5). Needs 04, 05, 06, 07 and the campaign notebook to have run first.

CREATE SCHEMA IF NOT EXISTS bi;

-- WEEKS: one row per week. complete_week is FALSE for weeks with fewer than 7 days of data,
-- so trend charts can leave them out.
CREATE OR REPLACE VIEW bi.dim_week AS
SELECT week_no,
       CASE WHEN week_no <= 52 THEN 1 ELSE 2 END        AS year_no,
       ((week_no - 1) % 52) + 1                          AS week_of_year,
       'Q' || (((week_no - 1) / 13) + 1)                 AS quarter_label,
       COUNT(DISTINCT day)                               AS days_with_data,
       COUNT(DISTINCT day) >= 7                          AS complete_week
FROM clean.baskets
GROUP BY week_no;

-- TRIPS: one row per shopping trip (the main fact table for the overview page)
CREATE OR REPLACE VIEW bi.fact_baskets AS
SELECT basket_id, household_key, store_id, day, week_no,
       basket_value, items, lines, discount, used_coupon
FROM clean.baskets;

-- CATEGORIES: one row per category per week
CREATE OR REPLACE VIEW bi.fact_category_week AS
SELECT department, commodity_desc, week_no, sales, units, discount, baskets, households
FROM clean.weekly_category_sales;

-- HOUSEHOLDS: one row per household with RFM segment, churn flags, campaigns, coupons, demographics
CREATE OR REPLACE VIEW bi.dim_household AS
SELECT r.household_key,
       r.segment,
       r.r_score, r.f_score, r.m_score,
       r.days_since_last, r.trips, r.sales,
       r.gone_quiet, r.fading,
       (r.gone_quiet OR r.fading)      AS churn_risk,
       r.last_13w_sales, r.prev_13w_sales,
       h.campaigns_received,
       h.coupons_redeemed,
       (h.campaigns_received > 0)      AS targeted,
       (h.coupons_redeemed > 0)        AS redeemed,
       h.has_demographics,
       COALESCE(h.age_desc, 'Not known')       AS age_desc,
       CASE WHEN h.income_desc IN ('Under 15K', '15-24K', '25-34K')             THEN 'Under $35K'
            WHEN h.income_desc IN ('35-49K', '50-74K')                          THEN '$35-74K'
            WHEN h.income_desc IN ('75-99K', '100-124K')                        THEN '$75-124K'
            WHEN h.income_desc IS NOT NULL                                      THEN '$125K+'
            ELSE 'Not known' END               AS income_band,
       COALESCE(h.hh_comp_desc, 'Not known')   AS hh_comp_desc,
       COALESCE(h.homeowner_desc, 'Not known') AS homeowner_desc
FROM analysis.household_rfm r
JOIN clean.households h ON h.household_key = r.household_key;

-- PROMOTION UPLIFT: the Phase 4 summary with readable names
CREATE OR REPLACE VIEW bi.promo_uplift AS
SELECT CASE level WHEN '1. promo type' THEN 'Promotion type'
                  WHEN '2. display location (display-only weeks)' THEN 'Display location'
                  ELSE 'Mailer placement' END AS level,
       CASE WHEN level = '1. promo type' THEN placement
            WHEN level LIKE '2.%' THEN CASE placement
                 WHEN '1' THEN 'Store front'        WHEN '2' THEN 'Store rear'
                 WHEN '3' THEN 'Front end cap'      WHEN '4' THEN 'Mid-aisle end cap'
                 WHEN '5' THEN 'Rear end cap'       WHEN '6' THEN 'Side-aisle end cap'
                 WHEN '7' THEN 'In-aisle'           WHEN '9' THEN 'Secondary location'
                 WHEN 'A' THEN 'In-shelf'           ELSE placement END
            ELSE CASE placement
                 WHEN 'A' THEN 'Interior page feature'   WHEN 'C' THEN 'Interior page line item'
                 WHEN 'D' THEN 'Front page feature'      WHEN 'F' THEN 'Back page feature'
                 WHEN 'H' THEN 'Wrap front feature'      WHEN 'J' THEN 'Wrap interior coupon'
                 WHEN 'L' THEN 'Wrap back feature'       ELSE placement END
       END AS placement,
       promo_weeks, extra_sales, uplift_pct, avg_extra_per_week, ci95,
       avg_extra_per_week - ci95 AS ci_low,
       avg_extra_per_week + ci95 AS ci_high,
       net_extra_sales, discount_given, extra_per_discount_dollar
FROM analysis.uplift_summary
WHERE NOT (level LIKE '3.%' AND placement IN ('X', 'Z', 'P'));   -- free-item placements, see README

-- CANNIBALISATION by promo type
CREATE OR REPLACE VIEW bi.promo_cannibalisation AS
SELECT grp AS promo_type, promoted_extra, category_extra, taken_from_similar, taken_ci95, cannibalised_pct
FROM analysis.cannibalisation_summary
WHERE level = '2. promo type';

-- CAMPAIGN RESULTS: saved to the database by notebooks/02_campaign_impact.ipynb
CREATE OR REPLACE VIEW bi.campaign_results AS
SELECT * FROM analysis.campaign_did;

-- quick check: row counts of everything Power BI will import
SELECT 'dim_week' AS view_name, COUNT(*) AS rows FROM bi.dim_week
UNION ALL SELECT 'fact_baskets', COUNT(*) FROM bi.fact_baskets
UNION ALL SELECT 'fact_category_week', COUNT(*) FROM bi.fact_category_week
UNION ALL SELECT 'dim_household', COUNT(*) FROM bi.dim_household
UNION ALL SELECT 'promo_uplift', COUNT(*) FROM bi.promo_uplift
UNION ALL SELECT 'promo_cannibalisation', COUNT(*) FROM bi.promo_cannibalisation
UNION ALL SELECT 'campaign_results', COUNT(*) FROM bi.campaign_results;
