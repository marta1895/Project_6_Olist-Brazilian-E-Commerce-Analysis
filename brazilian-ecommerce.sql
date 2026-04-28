/*
Brazilian E-Commerce (Olist) — SQL EDA & Analysis
Dataset:  https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
Window:   Sep 2016 – Oct 2018 (trend analysis restricted to Aug 2017 – Aug 2018)
Author:   Marta
Updated:  2026-04-21

Sections:
  1. Business Overview        — revenue, orders, status mix, monthly trend
  2. Delivery Performance     — delivery time, on-time rate, impact on reviews
  3. Product & Category       — category performance, satisfaction deep-dive
  4. Seller Performance       — top sellers, scorecard, risk flags
  5. Customer Behavior        — revenue by state, retention, avg spend
  6. Payment Analysis         — payment mix, AOV, high-value orders

Helper view:
  olist — flat join of orders + items + reviews + customers + sellers + products,
          enriched with is_invalid_delivered flag for malformed delivery rows.
*/



---- SECTION 1. — Business Overview



-- 1. Total revenue, total orders, average order value
SELECT 
    ROUND(SUM(p.payment_value)::numeric, 2) AS total_revenue,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND((SUM(p.payment_value) / COUNT(DISTINCT o.order_id))::numeric, 2) AS avg_order_value
FROM orders o
JOIN payments p USING (order_id);
-- Total revenue of R$16008872.12 with total orders of 99440, and average order value (AOV) of R$160.99



-- 2. Order status breakdown — what % are delivered, cancelled, in progress
WITH unique_orders AS (
    SELECT DISTINCT 
    	order_id, 
    	order_status
    FROM orders
),
orders_groups AS (
    SELECT
        COUNT(order_id) AS total_orders,
		COUNT(CASE WHEN order_status = 'delivered' THEN order_id END) AS delivered_orders,
        COUNT(CASE WHEN order_status = 'canceled' THEN 1 END) AS canceled_orders,
        COUNT(CASE WHEN order_status IN ('shipped', 'invoiced', 'created', 'approved', 'processing') THEN 1 END) AS in_progress_orders,
        COUNT(CASE WHEN order_status = 'unavailable' THEN 1 END) AS unavailable_orders
    FROM unique_orders
)

SELECT
    ROUND(delivered_orders * 100.0 / total_orders, 2) AS delivered_orders_pct,
    ROUND(canceled_orders * 100.0 / total_orders, 2) AS canceled_orders_pct,
    ROUND(in_progress_orders * 100.0 / total_orders, 2) AS in_progress_orders_pct,
    ROUND(unavailable_orders * 100.0 / total_orders, 2) AS unavailable_orders_pct
FROM orders_groups;
-- The numbers exceed expectations of operational health — 97.02% Delivered,
-- 0.63% Canceled, 1.74% In Progress, 0.61% Unavailable.
	


-- 3. Monthly order volume trend — is the business growing?
-- Limited to Aug 2017 – Aug 2018 (13 months). Earlier months are the launch ramp
-- and late 2018 is cut off, so both would skew the trend. Raw data runs Jan 2017 – Oct 2018.
SELECT 
    TO_CHAR(DATE_TRUNC('month', order_purchase_timestamp), 'YYYY-MM') AS month,
    COUNT(DISTINCT o.order_id) AS orders,
    ROUND(SUM(p.payment_value)::numeric, 2) AS revenue
FROM orders o
JOIN payments p USING (order_id)
WHERE order_purchase_timestamp >= '2017-08-01'
  AND order_purchase_timestamp <  '2018-09-01'
GROUP BY month
ORDER BY month;
-- Orders grew ~50% YoY (Aug 2017 → Aug 2018), with a Nov 2017 spike likely from Black Friday. 
-- Growth stalled in 2018, oscillating between 6K–7K orders with no clear upward trend.



---- SECTION 2. — Delivery Performance



-- 4. Average delivery time by state — which states wait longest
-- Overall avg delivery time (baseline for state comparison)
SELECT
    COUNT(*) AS n_orders,
    ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400)::numeric, 2) AS avg_delivery_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400
    ) AS median_delivery_days
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_purchase_timestamp IS NOT NULL;

SELECT
	c.customer_state,
	-- Convert timestamp data type into number of days in order to find the average value
	ROUND(AVG(EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) / 86400), 2) AS avg_delivery_days
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
-- Previously, during the data cleansing I flagged invalid delivered orders (status = delivered but no delivery date)
-- A small number of such cases, but excluding them for cleaner results.
AND o.is_invalid_delivered = FALSE
GROUP BY c.customer_state
ORDER BY avg_delivery_days DESC;
-- Northern/Amazonian states (RR, AP, AM) wait 2–3× longer than southern states
-- (SP, PR, MG). Geography, not seller performance, drives the gap.


-- 5. On-time vs late delivery rate — compare order_delivered_customer_date vs order_estimated_delivery_date
WITH delivery_timeliness_group AS (
	SELECT 
		order_id,
		CASE 
			WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 'Late'
            WHEN order_delivered_customer_date <= order_estimated_delivery_date THEN 'On-time'
		END AS delivery_timeliness
	FROM orders
	WHERE order_status = 'delivered'
    AND order_delivered_customer_date IS NOT NULL
)
SELECT 
	ROUND(COUNT(CASE WHEN delivery_timeliness = 'Late' THEN 1 END) * 100.0 / COUNT(*), 1) AS late_pct,
	ROUND(COUNT(CASE WHEN delivery_timeliness = 'On-time' THEN 1 END) * 100.0 / COUNT(*), 1) AS on_time_pct
FROM delivery_timeliness_group;
-- 91.9% of delivered orders arrived on time, with only 8.1% late — delivery performance is strong overall.



-- 6. Late delivery impact on review score — do late orders get lower ratings?
WITH delivery_timeliness_group AS (
	SELECT 
		order_id,
		CASE 
			WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 'Late'
			WHEN order_delivered_customer_date <= order_estimated_delivery_date THEN 'On-time'
		END AS delivery_timeliness,
		review_score
	FROM orders o
	JOIN reviews r USING (order_id)
	WHERE order_status = 'delivered'
    AND order_delivered_customer_date IS NOT NULL
)
SELECT 
	delivery_timeliness,
	ROUND(AVG(review_score)::numeric, 2) AS avg_review_score
FROM delivery_timeliness_group
GROUP BY delivery_timeliness;
-- Late deliveries average 2.57 stars, on-time 4.29. Huge gap —
-- late delivery is a clear driver of bad reviews.



---- SECTION 3. — Product & Category Analysis



-- 7. Category performance: revenue, order volume, review scores, and satisfaction flag
-- Ranks categories by avg review score (asc) to find the most disappointing ones (min. 100 orders)
WITH order_reviews AS (
    SELECT 
	    order_id, 
	    AVG(review_score) AS review_score
    FROM reviews
    GROUP BY order_id
),

category_metrics AS (
    SELECT
        pc.product_category_name_english AS category,
        ROUND(SUM(oi.price + oi.freight_value)::numeric, 2) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS order_volume,
        ROUND(SUM(oi.price + oi.freight_value)::numeric 
              / NULLIF(COUNT(DISTINCT o.order_id), 0), 2) AS revenue_per_order,
        ROUND(AVG(orv.review_score)::numeric, 2) AS avg_review_score,
        COUNT(CASE WHEN orv.review_score BETWEEN 1 AND 3 THEN 1 END) AS low_reviews,
        COUNT(CASE WHEN orv.review_score BETWEEN 4 AND 5 THEN 1 END) AS high_reviews
    FROM order_items oi
    JOIN orders o            ON oi.order_id = o.order_id
    JOIN products pr         ON oi.product_id = pr.product_id
    JOIN product_category pc ON pr.product_category_name = pc.product_category_name
    LEFT JOIN order_reviews orv ON o.order_id = orv.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY pc.product_category_name_english
)
-- Find which product categories disappoint customers most
SELECT * 
FROM category_metrics
WHERE order_volume >= 100
ORDER BY avg_review_score ASC
LIMIT 20;
-- office_furniture has the lowest avg review score (3.51) despite ranking in the top revenue categories — flagged as a satisfaction risk.
-- Next: determine whether late delivery explains the low scores.
SELECT
    CASE WHEN product_category_en = 'office_furniture' 
         THEN 'office_furniture' ELSE 'all_others' END AS segment,
    ROUND(AVG(review_score)::numeric, 2) AS avg_review,
    ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400)::numeric, 2) AS avg_days,
    ROUND(COUNT(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 END)*100.0/COUNT(*), 1) AS late_pct
FROM olist
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
GROUP BY segment; 
-- office_furniture shows no meaningful difference in late delivery rate vs other categories — delivery is not the driver.
-- Next: inspect review text for score <= 3 to identify root cause.
WITH bad_reviews_summary AS (
	SELECT 
		oi.order_id,
		r.review_score,
		r.review_comment_title,
		r.review_comment_message
	FROM reviews r
	JOIN order_items oi ON r.order_id = oi.order_id
	JOIN products p ON oi.product_id = p.product_id
	JOIN product_category pc ON p.product_category_name = pc.product_category_name
	WHERE pc.product_category_name_english = 'office_furniture'
	AND r.review_score <= 3
)

SELECT 
	DISTINCT review_comment_message
FROM bad_reviews_summary; 
-- Bad reviews cluster around fulfillment issues: wrong item counts, missing parts, damaged goods on arrival.



-- 7a. Top 10 categories by revenue (for dashboard ranking chart)
WITH category_revenue AS (
    SELECT
        pc.product_category_name_english AS category,
        ROUND(SUM(oi.price + oi.freight_value)::numeric, 2) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS order_volume
    FROM order_items oi
    JOIN orders o            ON oi.order_id = o.order_id
    JOIN products pr         ON oi.product_id = pr.product_id
    JOIN product_category pc ON pr.product_category_name = pc.product_category_name
    WHERE o.order_status = 'delivered'
    GROUP BY pc.product_category_name_english
)
SELECT *
FROM category_revenue
ORDER BY total_revenue DESC
LIMIT 10;
-- health_beauty, watches_gifts, and bed_bath_table lead total revenue —
-- the same trio that dominated high-value orders in Q16.



---- SECTION 4. — Seller Performance



-- 8. Top 20 sellers by revenue
SELECT
    s.seller_id,
    ROUND(SUM(oi.price + oi.freight_value)::numeric, 2) AS total_revenue
FROM sellers s
JOIN order_items oi ON oi.seller_id = s.seller_id
GROUP BY s.seller_id
ORDER BY total_revenue DESC
LIMIT 20;
-- Top 20 sellers by total revenue; the gap between #1 (~250K) and #20 (~83K) is 3×,
-- indicating heavy revenue concentration at the top.



-- 9. Seller scorecard: combine average review score + late delivery rate + order volume into one query
WITH order_reviews AS (
    SELECT 
	    order_id, 
	    AVG(review_score) AS review_score
    FROM reviews
    GROUP BY order_id
),
sellers_metrics AS (
    SELECT
        oi.seller_id,
        COUNT(DISTINCT o.order_id) AS order_volume,
        ROUND(AVG(orv.review_score)::numeric, 2) AS avg_review_score,
        ROUND(COUNT(DISTINCT CASE 
            WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date 
            THEN o.order_id END) * 100.0 
            / NULLIF(COUNT(DISTINCT o.order_id), 0), 1) AS late_pct
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.order_id
    LEFT JOIN order_reviews orv ON o.order_id = orv.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY oi.seller_id
)
SELECT *
FROM sellers_metrics
WHERE order_volume >= 100
ORDER BY avg_review_score;
-- Seller scorecard reveals a clear pattern: higher late delivery rate correlates with lower review scores. 
-- Unlike office_furniture (where product issues drove dissatisfaction), delivery performance is the primary satisfaction driver at the seller level.



-- 10. Identify underperforming sellers — high volume but low rating or high late rate

-- Thresholds calibrated to dataset distribution:
--   avg_review < 3.5 → ~0.6 below dataset avg (4.1). 
--                      Seller needs a high share of 1–3★ ratings to appear here.
--   late_pct > 14.5  → ~2× dataset avg (7.62%). Clear delivery problem.
--   Both conditions met = High Risk; either = At Risk.
WITH order_reviews AS (
    SELECT 
    	order_id, 
    	AVG(review_score) AS review_score
    FROM reviews
    GROUP BY order_id
),
sellers_metrics AS (
    SELECT
        oi.seller_id,
        COUNT(DISTINCT o.order_id) AS order_volume,
        ROUND(AVG(orv.review_score)::numeric, 2) AS avg_review_score,
        ROUND(COUNT(DISTINCT CASE
            WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
            THEN o.order_id END) * 100.0
            / NULLIF(COUNT(DISTINCT o.order_id), 0), 1) AS late_pct
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.order_id
    LEFT JOIN order_reviews orv ON o.order_id = orv.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY oi.seller_id
),
flagged_sellers AS (
    SELECT
        seller_id,
        order_volume,
        avg_review_score,
        late_pct,
        CASE
            WHEN avg_review_score < 3.5 AND late_pct > 14.5 THEN 'High Risk'
            WHEN avg_review_score < 3.5 OR late_pct > 14.5 THEN 'At Risk'
            ELSE 'Healthy'
        END AS seller_flag
    FROM sellers_metrics
),
--select * from flagged_sellers 
--where order_volume >= 100
underperforming_sellers AS (
	SELECT *
	FROM flagged_sellers
	WHERE order_volume >= 100
  		AND seller_flag IN ('High Risk', 'At Risk') -- Found the underperforming sellers' ids and their metrics
),
-- Additionally, found top categories that drive underperforming sellers
seller_category_counts AS (
    SELECT 
    	oi.seller_id,
        pc.product_category_name_english AS category,
        COUNT(*) AS items_sold,
        ROW_NUMBER() OVER (PARTITION BY oi.seller_id
       		ORDER BY COUNT(*) DESC) AS rn
    FROM order_items oi
    JOIN products pr         ON oi.product_id = pr.product_id
    JOIN product_category pc ON pr.product_category_name = pc.product_category_name
    WHERE oi.seller_id IN (SELECT seller_id FROM underperforming_sellers)
    GROUP BY oi.seller_id, pc.product_category_name_english
)
SELECT 
	ups.*, 
	scc.category AS top_category, 
	scc.items_sold
FROM underperforming_sellers ups
LEFT JOIN seller_category_counts scc ON ups.seller_id = scc.seller_id 
	AND scc.rn = 1
ORDER BY ups.seller_flag, ups.late_pct DESC; 
-- 16 sellers flagged (min. 100 orders): 14 At Risk, 2 High Risk.
-- Pattern: Most issues are delivery-related (late delivery rate > 14.5%), even though review scores are still fairly good.
-- One seller stands out — low product quality (2.81 avg rating) despite only
-- moderate delivery delays, suggesting non-logistics problems.



---- SECTION 5. — Customer Behavior



-- 11. Revenue by customer state — where is the money coming from
WITH state_revenue AS (
    SELECT
        c.customer_state,
        SUM(oi.price + oi.freight_value) AS total_revenue
    FROM order_items oi
    JOIN orders o    ON oi.order_id = o.order_id
    JOIN customers c ON o.customer_id = c.customer_id
    GROUP BY c.customer_state
)
SELECT
    customer_state,
    ROUND(total_revenue::numeric, 2) AS total_revenue,
    ROUND(total_revenue::numeric * 100.0 / SUM(total_revenue) OVER (), 2) AS pct_of_total,
    ROUND(SUM(total_revenue::numeric) OVER (ORDER BY total_revenue DESC) * 100.0 
          / SUM(total_revenue) OVER (), 2) AS cumulative_pct
FROM state_revenue
ORDER BY total_revenue DESC;
-- Revenue is heavily concentrated: SP, RJ, and MG alone account for 62.5% of total revenue. 
-- The remaining 24 states split the other 37.5%, with 19 of them individually below 2%.



-- 12. One-time vs repeat customers — what % of customers ordered more than once
WITH customer_order_counts AS (
    SELECT
        c.customer_unique_id,
        COUNT(o.order_id) AS order_count
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_unique_id
)
SELECT
    ROUND(COUNT(CASE WHEN order_count = 1 THEN 1 END) * 100.0 / COUNT(*), 1) AS one_time_pct,
    ROUND(COUNT(CASE WHEN order_count > 1 THEN 1 END) * 100.0 / COUNT(*), 1) AS repeat_pct,
    COUNT(*) AS total_unique_customers
FROM customer_order_counts;
-- 96.9% one-time, 3.1% repeat. Almost no returning customers —
-- the business lives entirely on new acquisition.



-- 13. Average spend per customer by state
WITH revenue_per_customer AS (
    SELECT
        c.customer_unique_id,
        c.customer_state,
        SUM(oi.price + oi.freight_value) AS total_spend
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    JOIN order_items oi ON o.order_id = oi.order_id
    GROUP BY c.customer_unique_id, c.customer_state
)
SELECT
    customer_state,
    COUNT(*) AS unique_customers,
    ROUND(AVG(total_spend)::numeric, 2) AS avg_spend_per_customer
FROM revenue_per_customer
GROUP BY customer_state
ORDER BY avg_spend_per_customer DESC;
-- Smaller states spend more per customer on average; 
-- SP ranks last despite leading in total revenue — volume dilutes the average.



---- SECTION 6. — Payment Analysis



-- 14–15. Payment mix, average order value, and revenue share by payment type
-- Note: orders paid with mixed methods (e.g. voucher + credit card) appear
-- under each method. Sum of n_orders across types slightly exceeds total
-- unique orders. Same applies to revenue share.
WITH order_payment_totals AS (
    SELECT 
    	order_id,
        payment_type,
        SUM(payment_value)::numeric AS order_value
    FROM payments
    GROUP BY order_id, payment_type
)
SELECT
    payment_type,
    COUNT(*)                                                           AS n_orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)                 AS pct_of_orders,
    ROUND(AVG(order_value), 2)                                         AS avg_order_value,
    ROUND(SUM(order_value), 2)                                         AS total_revenue,
    ROUND(SUM(order_value) * 100.0 / SUM(SUM(order_value)) OVER (), 2) AS pct_of_revenue
FROM order_payment_totals
GROUP BY payment_type
ORDER BY pct_of_orders DESC;
-- Credit card dominates at 75% of orders and 78% of revenue, with the highest avg order value (167). 
-- Boleto is a distant second at 20% of orders. Vouchers and debit cards are insignificant.



-- 16. High value orders — top quartile orders (P75), what categories dominate them
-- High-value cutoff = P75 (top 25% of orders).
-- Mean is skewed by a few big orders, so percentile is more honest here.
WITH order_totals AS (
    SELECT 
    	oi.order_id,
        SUM(oi.price + oi.freight_value)::numeric AS order_value
    FROM order_items oi
    GROUP BY oi.order_id
),
threshold AS (
    SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY order_value) AS p75_order_value
    FROM order_totals
),
high_value_orders AS (
    SELECT ot.order_id
    FROM order_totals ot
    CROSS JOIN threshold t
    WHERE ot.order_value > t.p75_order_value
)
SELECT 
	pc.product_category_name_english,
    COUNT(DISTINCT oi.order_id) AS high_value_orders,
    ROUND(COUNT(DISTINCT oi.order_id) * 100.0
       / (SELECT COUNT(*) FROM high_value_orders), 2) AS pct_of_hv_orders
FROM order_items oi
JOIN high_value_orders hv ON oi.order_id = hv.order_id
JOIN products pr          ON oi.product_id = pr.product_id
JOIN product_category pc  ON pr.product_category_name = pc.product_category_name
GROUP BY pc.product_category_name_english
HAVING COUNT(DISTINCT oi.order_id) >= 30  -- minimum volume to avoid niche noise
ORDER BY high_value_orders DESC
LIMIT 10;
-- Top 25% orders (by value) are led by watches_gifts, health_beauty, and bed_bath_table — together accounting for ~27% of all high-value orders. 
-- These are the categories driving premium spend.

SELECT
    ROUND(AVG(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400)::numeric, 2) AS avg_delivery_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400
    ) AS median_delivery_days,
    MIN(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400) AS min_days,
    MAX(EXTRACT(EPOCH FROM (order_delivered_customer_date - order_purchase_timestamp))/86400) AS max_days
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;



/* =====================================================================
   KEY FINDINGS
   =====================================================================
   Business health
   - Retention is broken: 96.9% of customers order once, 3.1% return.
     The business lives entirely on new acquisition.
   - Revenue is heavily concentrated in São Paulo (~37.38% of total).

   Delivery
   - On-time deliveries average 4.29★; late ones average 2.57★.
     A 1.7★ gap — delivery timing is the single biggest driver of ratings.

   Product/category
   - office_furniture underperforms on reviews despite strong revenue.
     Late delivery is NOT the cause — customer complaints focus on
     wrong item counts, missing parts, damaged goods.

   Sellers
   - 16 sellers flagged as At Risk or High Risk (avg_review < 3.5 OR late_pct > 14.5,
     min. 100 orders). Risk is spread across 11+ categories — not concentrated,
     suggesting delivery/fulfillment problems are seller-level, not category-level.

   Payments
   - Credit card is the dominant method: 75% of orders, 78% of revenue, highest average order value (~R$167).
   - Boleto is distant second (20% of orders). Voucher and debit card are insignificant.
   - Top-quartile orders are concentrated in watches_gifts, health_beauty, and
     bed_bath_table (top 3 = ~27% of high-value orders). Ten categories account
     for the majority of premium spend.
   ===================================================================== */