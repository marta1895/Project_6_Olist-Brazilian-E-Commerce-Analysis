# Brazilian E-Commerce (Olist) — End-to-End Analysis

End-to-end analysis of the Olist marketplace dataset (2016–2018, ~100K orders): data cleaning in Python, exploratory and diagnostic SQL in PostgreSQL, and an executive Tableau dashboard. The goal was not to repeat headline metrics, but to find where the business actually leaks value — retention, late deliveries, review damage, and seller-level fulfillment risk.

## Dashboard preview

<img width="3400" height="2400" alt="dashboard" src="https://github.com/user-attachments/assets/03ae0a76-444b-4267-9032-72171f0006d6" />


Interactive version on Tableau Public: *https://public.tableau.com/app/profile/marta.narozhnyak/viz/Olist_E-Commerce_Analysis/OlistBrazilianE-CommerceAnalysisDashboard*

## Data

Source: [Brazilian E-Commerce Public Dataset by Olist — Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce/)

Nine relational tables covering orders, order items, payments, reviews, products, sellers, customers, geolocation, and product-category translations. Dataset window: September 2016 – October 2018. All Brazilian states represented, with heavy concentration in the Southeast.

## Tech stack

- **Python / Jupyter** — initial data inspection, null handling, dtype fixes, validation of "delivered with no delivery date" anomalies.
- **PostgreSQL (DBeaver)** — schema setup, full SQL EDA across six analytical sections, CTEs, window functions, and percentile aggregates.
- **Tableau Desktop / Public** — final dashboard with KPI cards, gauge chart, scatter, and category breakdowns.

## Repository structure

```
.
├── brazilian-ecommerce_cleaning.ipynb     # Python: data inspection + cleaning, table-by-table null/dtype audit
├── brazilian-ecommerce_analysis.sql       # PostgreSQL: 6-section analytical EDA (Q1–Q16) + Key Findings block
├── Olist_Visualisation.twbx               # Tableau packaged workbook (open in Tableau Desktop / Public)
├── dashboard.png                          # Static export of the final dashboard
└── README.md
```

## Analysis structure (SQL)

The SQL file is organized into six sections, each tied to a specific business question rather than a generic "explore the data" pass.

| Section | Theme | What it answers |
| --- | --- | --- |
| 1 | Business Overview | Order volume, revenue, monthly trend, state-level revenue concentration |
| 2 | Delivery Performance | Average delivery time overall and by state, late-delivery rate, on-time vs. late buckets |
| 3 | Product & Category Analysis | Top categories by revenue, review-score outliers, category-level satisfaction risks |
| 4 | Seller Performance | Per-seller volume, avg review, late-delivery %, At Risk / High Risk flagging, top categories per seller |
| 5 | Customer Behavior | Repeat-purchase rate, time-window adjusted retention, customer geography |
| 6 | Payment Analysis | Method mix (credit card / boleto / voucher / debit), AOV by method, premium-spend categories |

A `KEY FINDINGS` block at the end of the SQL file consolidates the conclusions (mirrored below).

## Key findings

**Retention is broken.** 96.9% of customers buy once and never return; the repeat rate is 3.1%. Even adjusting for the dataset's two-year window, that sits 5–10× below normal marketplace retention. The business is running on paid acquisition.

**Revenue is geographically concentrated.** São Paulo alone accounts for ~37% of revenue. SP + RJ + MG together = ~62.5%. Any logistics or marketing decision needs to weight the Southeast.

**Late delivery is the single largest review driver.** On-time orders average 4.29★; late orders average 2.57★ — a 1.7★ gap. Delivery timing, not product, is the dominant lever on satisfaction.

**`office_furniture` is a product problem, not a delivery problem.** Reviews are weak despite normal delivery performance. Complaints cluster around wrong quantities, missing parts, and damaged goods — a sourcing / packaging issue.

**Seller risk is fulfillment-level, not category-level.** 16 sellers were flagged At Risk or High Risk (avg review < 3.5 OR late % > 14.5, min. 100 orders). They span 11+ categories, so the problem is operational (specific sellers), not vertical.

**Payments are credit-card-dominant.** Credit card = 75% of orders and 78% of revenue, with the highest AOV (~R$167). Boleto is a distant second at 20%. Voucher and debit are negligible.

**Premium spend concentrates in three categories.** `watches_gifts`, `health_beauty`, and `bed_bath_table` together drive ~27% of top-quartile orders.

## How to reproduce

1. Download the dataset from Kaggle (link above) and load the nine CSVs into a PostgreSQL database. Table names used in the SQL file: `orders`, `order_items`, `payments`, `reviews`, `products`, `sellers`, `customers`, `geolocation`, `product_category`.
2. Run `brazilian-ecommerce.ipynb` to reproduce the cleaning steps (null handling on `orders`, `reviews`, `products`).
3. Run `brazilian-ecommerce.sql` section by section in DBeaver (or any Postgres client). Each section is self-contained and commented.
4. Open `Olist_Visualisation.twbx` in Tableau Desktop or Tableau Public to explore the dashboard.
