# Data notes

The detail behind the README: what each table holds, how they join, what I cleaned and why. [Back to the README](../README.md)

## The data

The 8 Kaggle CSVs are loaded into a local **PostgreSQL** database with `src/load_raw.py`, which creates the tables from `sql/01_create_raw_tables.sql` and bulk-loads about 40 million rows. `sql/02_profile_raw.sql` then checks row counts, unique keys, date coverage and joins.

### The tables

| Table | One row = | Unique key | Rows | Covers |
|---|---|---|---|---|
| `transaction_data` | one product bought on one shopping trip | `basket_id` + `product_id` | 2,595,732 | days 1–711, weeks 1–102, 582 stores, 2,500 households |
| `causal_data` | one product in one store in one week, with its display and mailer placement | `product_id` + `store_id` + `week_no` *(15,245 repeats)* | 36,786,524 | weeks 9–101, **115 stores** |
| `product` | one product | `product_id` | 92,353 | |
| `hh_demographic` | one household | `household_key` | 801 | 801 of 2,500 households |
| `campaign_desc` | one campaign | `campaign` | 30 | day 224 to day 719 |
| `campaign_table` | one household targeted by one campaign | `household_key` + `campaign` | 7,208 | 1,584 households |
| `coupon` | one product covered by one coupon in one campaign | none *(5,164 exact repeats)* | 124,548 | |
| `coupon_redempt` | one coupon redeemed by one household on one day | | 2,318 | |

### How they join

![How the tables join](er_diagram.png)

The join that matters most is **transactions to promotions on `product_id` + `store_id` + `week_no`**. That's how I know whether a product was on display or in the mailer in the week someone bought it.

Every purchase matches a product, and every redeemed coupon matches a coupon in the coupon table, so nothing gets lost when joining.

<details>
<summary><b>Column guide</b> (click to open)</summary>

**transaction_data**

| Column | Meaning |
|---|---|
| `household_key` | Household ID |
| `basket_id` | Shopping trip ID. One basket = one trip |
| `day` | Day number, 1–711. There are no real dates |
| `product_id` | Product ID, joins to `product` |
| `quantity` | Units bought |
| `sales_value` | Dollars the store received for this line, after discounts |
| `store_id` | Store ID |
| `retail_disc` | Loyalty-card discount from the store, stored as a negative number |
| `trans_time` | Time of day as HHMM, e.g. 1631 = 4:31 pm |
| `week_no` | Week number, 1–102 |
| `coupon_disc` | Manufacturer coupon discount (negative) |
| `coupon_match_disc` | Extra discount when the store matches a manufacturer coupon (negative) |

**causal_data (promotions)**

| Column | Meaning |
|---|---|
| `product_id`, `store_id`, `week_no` | Which product, where, and when |
| `display` | Where it was displayed in store. `0` = not on display. Other codes per dunnhumby's guide: 1 store front, 2 store rear, 3 front end cap, 4 mid-aisle end cap, 5 rear end cap, 6 side-aisle end cap, 7 in-aisle, 9 secondary location, A in-shelf |
| `mailer` | Where it appeared in the weekly mailer. `0` = not in the mailer. A interior page feature, C interior page line item, D front page feature, F back page feature, H wrap front feature, J wrap interior coupon, L wrap back feature, P interior page coupon, X free on interior page, Z free on front/back page or wrap |

**product**

| Column | Meaning |
|---|---|
| `product_id` | Product ID |
| `manufacturer` | Manufacturer code |
| `department` | Broad area, e.g. GROCERY, PRODUCE, DRUG GM |
| `brand` | National (a big brand) or Private (store brand) |
| `commodity_desc` | Category, e.g. SOFT DRINKS |
| `sub_commodity_desc` | Subcategory. Used to find "similar products" when checking cannibalisation |
| `curr_size_of_product` | Pack size as text, e.g. 12 OZ |

**hh_demographic**

| Column | Meaning |
|---|---|
| `household_key` | Household ID |
| `age_desc` | Age band of the head of household, e.g. 25-34 |
| `marital_status_code` | A = married, B = single, U = unknown |
| `income_desc` | Income band, e.g. 50-74K |
| `homeowner_desc` | Homeowner, renter, unknown |
| `hh_comp_desc` | Household make-up, e.g. 2 Adults Kids |
| `household_size_desc` | Number of people, 1 to 5+ |
| `kid_category_desc` | Number of children, 1 to 3+, or None/Unknown |

**Campaigns and coupons**

| Table.column | Meaning |
|---|---|
| `campaign_desc.description` | Campaign type: TypeA, TypeB or TypeC |
| `campaign_desc.start_day`, `end_day` | When the campaign ran, as day numbers |
| `campaign_table.household_key`, `campaign` | Which households were sent which campaign |
| `coupon.coupon_upc` | Coupon ID. One coupon can cover many products |
| `coupon.product_id` | A product the coupon can be used on |
| `coupon_redempt.day` | Day the household used the coupon |

</details>

### What the profiling turned up

1. **Promotion data only covers 115 of the 582 stores.** The uplift analysis is limited to those stores. Otherwise products elsewhere would look "never promoted" just because nobody tracked them.
2. **Promotion data only covers weeks 9–101.** Weeks 1–8 and 102 are left out of the uplift analysis.
3. **Campaigns run from day 224 to day 719.** The first one starts about 32 weeks in, which leaves a good "before" period for the campaign analysis. The last one ends after the data stops (day 711), so its "during" period is cut short.
4. **One row per basket and product is unique.** Buying 3 of the same item is one row with quantity 3, not three rows.
5. **To clean in Process:** 15,245 repeated product–store–week rows in the promotions table, 5,164 exact repeats in the coupon table, and some positive values in `retail_disc`, a column that should only be negative.

## Cleaning

I ran 14 data-quality checks in SQL (`sql/03_quality_checks.sql`): nulls, duplicates, zero and negative values, outliers, day/week logic and products with no category. Then I built a **clean layer** (`sql/04_clean_views.sql`) that everything after this point reads from. The raw tables stay untouched.

### Cleaning log

| # | What I found | What I did | Why | Rows affected |
|---|---|---|---|---|
| 1 | No nulls in any key column | Nothing | | 0 |
| 2 | **Fuel (KIOSK-GAS)**: $544K of sales, quantities up to 89,638 (gallons) | Excluded | Grocery promotions don't apply to fuel, and gallons would distort every per-item number | 22,059 |
| 3 | **MISC SALES TRAN**: store-level transactions, quantities up to 85,055 | Excluded | Not products | 6,050 |
| 4 | **490 products with "NO COMMODITY DESCRIPTION"** (MISC. TRANS.) | Excluded | No category, so they can't be used in category or cannibalisation analysis | 2,351 |
| 5 | **15 products with a blank department**, all at $0 | Excluded | Placeholder or voided lines | 7,839 |
| 6 | **COUP/STR & MFG**: coupons scanned as items | Excluded | Not products | 817 |
| 7 | Lines with **quantity 0 or $0 sales** in the remaining departments | Dropped | Nothing sold or nothing paid; they'd inflate item counts | 10,504 |
| 8 | **10 rows with a positive `retail_disc`** | Kept the sale, set that discount to 0 | A discount can't raise the price, so I treat it as an error | 10 |
| 9 | Discounts stored as **negative numbers** | Turned them into positive dollar amounts | Easier to add up and read | all |
| 10 | **5,164 exact duplicate rows** in `coupon` | Removed the copies | Would inflate coupons per campaign | 5,164 |
| 11 | **15,245 product–store–weeks with two different placements** in `causal_data`, none of them exact copies | Kept one row each; if either record shows a display or mailer, I count it as promoted | 0.04% of the table, and "promoted in either record" is the safer reading | 15,245 |
| 12 | Every week spans 7 days, all times are valid, every redemption falls inside its campaign | Nothing | | 0 |

After removing fuel and the other non-products, the largest quantity left is 144 (produce sold by count), so I didn't need an outlier rule.

### What cleaning changed

| | Raw | Clean | Removed |
|---|---|---|---|
| Purchase lines | 2,595,732 | 2,546,112 | 49,620 (1.9%) |
| Sales | $8,057,463 | **$7,381,555** | $675,908 (8.4%) |
| Shopping trips | 276,484 | 251,063 | 25,421 (9.2%) |
| Households | 2,500 | 2,500 | 0 |

The one surprise was the **25,421 trips that disappeared**. Those were visits where someone bought only fuel or other non-product items, so once those lines went, the whole trip went with them.

I use **$8.06M** when talking about total store sales and **$7.38M** for everything in the analysis. On the clean data, the sales tree becomes: **2,500 households × 100.4 trips × $29.40 per trip = $7.38M**.

### The clean layer

| Object | One row = | Used for |
|---|---|---|
| `clean.transactions` | one product on one trip (merchandise only) | the base for everything else |
| `clean.promotions` | one product in one store in one week, with display and mailer flags | promotion flags |
| `clean.weekly_product_store_sales` | one product in one store in one week, with sales, units, discount and promo flags | the uplift analysis |
| `clean.weekly_category_sales` | one category in one week | category trends |
| `clean.baskets` | one shopping trip: value, items, lines, discount | trips and basket value |
| `clean.households` | one household: trips, sales, campaigns received, coupons redeemed, demographics | campaign impact and customer segments |
| `clean.coupons`, `clean.campaigns` | de-duplicated coupons; campaigns with length and households reached | campaign analysis |

### Keeping queries fast

With a 36-million-row table, a careless query can take minutes. What I did about it:

- **Indexes** on the columns I join on (`product_id`, `store_id`, `week_no`, `basket_id`), so PostgreSQL can jump straight to matching rows instead of scanning the whole table.
- **Materialized views** for anything built on the big tables. The heavy work happens once when I build them, not every time I query.
- **Only the columns I need**, never `SELECT *`, and filters as early as possible.
- **`EXPLAIN ANALYZE`** in front of a slow query to see whether it's using an index or scanning everything.
