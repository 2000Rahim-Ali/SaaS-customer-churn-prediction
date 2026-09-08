# SaaS Customer Churn Prediction

**Why Are We Losing Customers? Churn Diagnosis & Retention Strategy for a B2B Project Management SaaS Company**

A full-cycle data analytics project that diagnoses why customers churn from a B2B project management SaaS platform and translates the findings into a prioritized, KPI-backed retention strategy — built entirely in PostgreSQL.


## Project Overview

This project investigates customer churn for a B2B Project Management SaaS company using SQL as the primary analytical tool. It moves through the full analytics lifecycle: data modeling, cleaning, exploratory data analysis, advanced SQL diagnostics, predictive risk scoring, and business recommendations — all grounded in a relational data warehouse built in PostgreSQL.

The goal isn't just to report *that* customers are churning, but to answer *why*, *who is at risk next*, and *what the business should do about it*.

## Business Problem

The company is losing customers at a rate that affects recurring revenue, and leadership needs answers to:
- What is our actual churn rate, and how is it trending?
- Which customer segments are most at risk?
- What behavioral and support signals precede churn?
- Can we predict which active customers are likely to churn next?
- What retention actions should the business prioritize?

## Key Findings

- **Overall churn rate: 10.21%**
- **28.40% of all churn happens within a customer's first 6 months** — onboarding and early engagement are critical windows.
- **ARPU is not a meaningful churn differentiator** — churned customers averaged $34.57/month vs. $34.97/month for retained customers, ruling out price as a primary driver.
- Engagement trajectory, support ticket patterns, and payment failure timing surfaced as stronger churn signals than pricing or plan tier.

## Data Model

The project uses a star-schema-style warehouse in PostgreSQL with **12 tables**, including:

| Table | Purpose |
|---|---|
| `dim_customers` | Customer attributes and account metadata |
| `dim_date` | Date dimension for time-based analysis |
| `dim_complaint_theme` | Categorized support complaint themes |
| `fact_customer_monthly_snapshot` | Monthly customer state snapshots |
| `fact_engagement_monthly` | Monthly product engagement metrics |
| `fact_usage_monthly` | Monthly feature/product usage |
| `fact_support_tickets` | Support ticket history and resolution data |
| `fact_payment_attempts` | Billing and payment attempt history |
| `fact_surveys` | Customer sentiment/survey responses |
| `fact_churn_predictions` | Model-driven churn risk scores and tiers |
| `customer_churn_clean` | Consolidated, analysis-ready customer view (47 columns) |

## Tech Stack

- **PostgreSQL** — data modeling, cleaning, and all analysis
- **SQL** — CTEs, window functions, advanced joins, and aggregations
- **AI-assisted SQL development** — used to accelerate query drafting and validation, with results independently verified

## Methodology

The project follows a structured, staged workflow:

1. **Data Discovery & Modeling** — schema design and table creation
2. **Data Quality Assessment & Cleaning** — documented cleaning decisions
3. **Exploratory Data Analysis (EDA)** — 8 focus areas including churn trend, segment profiling, tenure at churn, engagement trajectory, support ticket patterns, and payment failure timing
4. **Advanced SQL Analysis** — 32 business questions answered across 5 categories: descriptive, diagnostic, risk, predictive, and prescriptive
5. **Analytical Validation** — cross-checking key metrics with independent queries
6. **Consolidated Findings & Product Insights**
7. **Recommendations** — a business action plan with KPI and impact measurement

## Recommendations & Business Impact

The final analysis translates findings into a prioritized **Business Action Plan** with an accompanying **KPI & Impact Measurement framework**, focused on:
- Strengthening the first-6-month onboarding experience to address the highest concentration of early churn
- Using engagement and support signals — rather than pricing — as early warning indicators for at-risk accounts
- Operationalizing churn risk tiers (`Critical` / `High` / `Medium` / `Low`) to guide proactive customer success outreach




*This project was built as an end-to-end demonstration of SQL-driven product analytics for SaaS retention strategy.*
