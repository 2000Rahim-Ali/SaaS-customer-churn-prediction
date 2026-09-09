-- ============================================================================
-- SaaS Customer Churn Prediction — Exploratory Data Analysis (EDA)
-- Project: Why Are We Losing Customers? Churn Diagnosis & Retention Strategy For a B2B Project Management SaaS Company
-- Tool: PostgreSQL (pgAdmin)
-- ============================================================================
-- PURPOSE:
-- This script performs exploratory data analysis across 8 focus areas to
-- diagnose churn drivers before moving into advanced/predictive SQL analysis.
-- ============================================================================


-- ============================================================================
-- 1. CHURN RATE & TREND
-- Business Question: What is our overall churn rate, and how is it trending
-- over time (e.g., by signup cohort or by month)?
-- Insight: Establishes the baseline churn rate and reveals whether churn is
-- improving, worsening, or seasonal — critical context for every other metric.
-- ============================================================================

-- 1a. Overall churn rate
SELECT
    COUNT(*) AS total_customers,
    SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) AS churned_customers,
    ROUND(
        100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS churn_rate_pct
FROM customer_churn_clean;

-- 1b. Churn trend by signup cohort month
-- Shows whether customers who signed up in certain months churn at higher rates
SELECT
    DATE_TRUNC('month', signup_date)::date AS signup_cohort,
    COUNT(*) AS cohort_size,
    SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) AS churned,
    ROUND(
        100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS cohort_churn_rate_pct
FROM customer_churn_clean
GROUP BY DATE_TRUNC('month', signup_date)
ORDER BY signup_cohort;

-- 1c. Churn trend by churn month (when customers actually left)
-- Reveals whether churn volume is increasing/decreasing period over period
SELECT
    DATE_TRUNC('month', churn_date)::date AS churn_month,
    COUNT(*) AS customers_churned
FROM dim_customers
WHERE customer_status = 'Churned'
  AND churn_date IS NOT NULL
GROUP BY DATE_TRUNC('month', churn_date)
ORDER BY churn_month;


-- ============================================================================
-- 2. CUSTOMER SEGMENT PROFILING
-- Business Question: How does churn behavior and customer profile differ
-- across key segments (contract type, company size, industry, etc.)?
-- Insight: Pinpoints which segments are disproportionately at risk, guiding
-- where retention resources should be focused first.
-- ============================================================================

-- 2a. Churn rate by contract type (proxy for plan tier — no plan_type column)
SELECT
    contract_type,
    COUNT(*) AS total_customers,
    SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) AS churned,
    ROUND(
        100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS churn_rate_pct
FROM customer_churn_clean
GROUP BY contract_type
ORDER BY churn_rate_pct DESC;

-- 2b. Churn rate by risk tier (validates whether risk tiers actually track real churn)
SELECT
    risk_tier,
    COUNT(*) AS total_customers,
    SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) AS churned,
    ROUND(
        100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS churn_rate_pct
FROM customer_churn_clean
GROUP BY risk_tier
ORDER BY churn_rate_pct DESC;

-- 2c. Multi-dimensional segment view: contract type x tenure bucket
-- Surfaces compound risk (e.g., "month-to-month + new customer" combinations)
SELECT
    contract_type,
    tenure_bucket,
    COUNT(*) AS total_customers,
    ROUND(
        100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS churn_rate_pct
FROM customer_churn_clean
GROUP BY contract_type, tenure_bucket
ORDER BY contract_type, tenure_bucket;


-- ============================================================================
-- 3. ARPU DISTRIBUTION
-- Business Question: How does Average Revenue Per User differ between
-- churned and retained customers, and across segments?
-- Insight: Determines whether pricing/revenue level is a churn driver, or
-- whether churn is driven by non-price factors (as prior analysis found).
-- ============================================================================
-- 3a. ARPU summary stats: churned vs retained
SELECT
    customer_status,
    COUNT(*) AS customers,
    ROUND(AVG(arpu), 2) AS avg_arpu,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arpu)::numeric, 2
    ) AS median_arpu,
    ROUND(MIN(arpu), 2) AS min_arpu,
    ROUND(MAX(arpu), 2) AS max_arpu,
    ROUND(STDDEV(arpu), 2) AS stddev_arpu
FROM customer_churn_clean
GROUP BY customer_status;

-- ARPU Comparison: Churned customers & Retained_customers 
SELECT
    ROUND(AVG(CASE WHEN churn = 1 THEN monthly_fee END)::numeric, 2) AS avg_arpu_churned,
    ROUND(AVG(CASE WHEN churn = 0 THEN monthly_fee END)::numeric, 2) AS avg_arpu_retained
FROM customer_churn_clean;


-- 3b. ARPU distribution by bucket, split by churn status
-- Useful for spotting whether churn clusters at low, mid, or high ARPU bands
SELECT
    CASE
        WHEN arpu < 20 THEN 'Under $20'
        WHEN arpu BETWEEN 20 AND 39.99 THEN '$20–$39.99'
        WHEN arpu BETWEEN 40 AND 59.99 THEN '$40–$59.99'
        ELSE '$60+'
    END AS arpu_band,
    customer_status,
    COUNT(*) AS customers
FROM customer_churn_clean
GROUP BY 1, customer_status
ORDER BY 1, customer_status;

-- 3c. ARPU by contract type (churned only) — identifies which plan tiers lose the most revenue
SELECT
    contract_type,
    COUNT(*) AS churned_customers,
    ROUND(SUM(arpu), 2) AS total_lost_mrr,
    ROUND(AVG(arpu), 2) AS avg_arpu_lost
FROM customer_churn_clean
WHERE customer_status = 'Churned'
GROUP BY contract_type
ORDER BY total_lost_mrr DESC;


-- ============================================================================
-- 4. TENURE AT CHURN
-- Business Question: How long do customers typically stay before churning,
-- and at what tenure milestones is churn risk highest?
-- Insight: Identifies the critical retention window (e.g., onboarding period)
-- where intervention would have the greatest impact.
-- ============================================================================

-- 4a. Tenure distribution among churned customers
SELECT
    tenure_bucket,
    COUNT(*) AS churned_customers,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2
    ) AS pct_of_all_churn
FROM customer_churn_clean
WHERE customer_status = 'Churned'
GROUP BY tenure_bucket
ORDER BY tenure_bucket;

-- 4b. Average and median tenure at churn (in months) — overall benchmark
SELECT
    ROUND(AVG(tenure_months), 1) AS avg_tenure_at_churn,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tenure_months)::numeric, 1
    ) AS median_tenure_at_churn
FROM customer_churn_clean
WHERE customer_status = 'Churned';

-- 4c. Early churn flag: % of churn happening within the first 6 months
SELECT
    SUM(CASE WHEN tenure_months <= 6 THEN 1 ELSE 0 END) AS churned_within_6mo,
    COUNT(*) AS total_churned,
    ROUND(
        100.0 * SUM(CASE WHEN tenure_months <= 6 THEN 1 ELSE 0 END) / COUNT(*), 2
    ) AS pct_early_churn
FROM customer_churn_clean
WHERE customer_status = 'Churned';


-- ============================================================================
-- 5. ENGAGEMENT TRAJECTORY
-- Business Question: How does product engagement change in the months
-- leading up to churn, compared to retained customers?
-- Insight: Declining engagement often precedes churn — spotting the drop-off
-- pattern enables proactive, engagement-triggered retention outreach.
-- ============================================================================
-- 5a. Average engagement score by "months before churn" (churned customers only)
SELECT
    fe.usage_month,
    c.churn_date,
    -- months_before_churn: negative = before churn, 0 = churn month
    (DATE_PART('year', c.churn_date) - DATE_PART('year', fe.usage_month)) * 12
        + (DATE_PART('month', c.churn_date) - DATE_PART('month', fe.usage_month)) AS months_before_churn,
    ROUND(AVG(fe.engagement_score), 2) AS avg_engagement_score
FROM fact_engagement_monthly fe
JOIN dim_customers c
    ON fe.customer_id = c.customer_id
WHERE c.customer_status = 'Churned'
  AND c.churn_date IS NOT NULL
GROUP BY fe.usage_month, c.churn_date
ORDER BY months_before_churn;


-- 5b. Engagement score comparison: churned vs retained (current/latest snapshot)
SELECT
    c.customer_status,
    ROUND(AVG(c.engagement_score), 2) AS avg_engagement_score
FROM customer_churn_clean c
GROUP BY c.customer_status;
-- (unchanged — this one pulls from customer_churn_clean, not fact_engagement_monthly)


-- 5c. Engagement decline flag: customers whose engagement dropped >30%
-- comparing their first vs most recent monthly snapshot
WITH engagement_bounds AS (
    SELECT
        customer_id,
        FIRST_VALUE(engagement_score) OVER (
            PARTITION BY customer_id ORDER BY usage_month
        ) AS first_engagement,
        LAST_VALUE(engagement_score) OVER (
            PARTITION BY customer_id ORDER BY usage_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS latest_engagement
    FROM fact_engagement_monthly
)
SELECT
    c.customer_status,
    COUNT(DISTINCT eb.customer_id) AS customers_with_engagement_drop
FROM engagement_bounds eb
JOIN customer_churn_clean c ON c.customer_id = eb.customer_id
WHERE eb.first_engagement > 0
  AND (eb.latest_engagement - eb.first_engagement) / eb.first_engagement <= -0.30
GROUP BY c.customer_status;


-- ============================================================================
-- 6. SUPPORT TICKET PATTERNS
-- Business Question: Do churned customers file more support tickets, escalate
-- more often, or experience slower resolution than retained customers?
-- Insight: High ticket volume, frequent escalation, or slow resolution can
-- signal frustration that leads to churn — a fixable operational driver.
-- ============================================================================

-- 6a. Average ticket volume and escalation rate: churned vs retained
SELECT
    c.customer_status,
    COUNT(DISTINCT t.ticket_id) AS total_tickets,
    COUNT(DISTINCT t.customer_id) AS customers_with_tickets,
    ROUND(COUNT(t.ticket_id)::numeric / NULLIF(COUNT(DISTINCT t.customer_id), 0), 2) AS avg_tickets_per_customer,
    ROUND(
        100.0 * SUM(CASE WHEN t.escalated THEN 1 ELSE 0 END) / COUNT(t.ticket_id), 2
    ) AS escalation_rate_pct,
    ROUND(AVG(t.resolution_time_hours), 2) AS avg_resolution_hours
FROM fact_support_tickets t
JOIN customer_churn_clean c ON c.customer_id = t.customer_id
GROUP BY c.customer_status;

-- 6b. Top complaint themes among churned customers
SELECT
    dt.theme_name,
    COUNT(*) AS ticket_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_churned_tickets
FROM fact_support_tickets t
JOIN customer_churn_clean c ON c.customer_id = t.customer_id
JOIN dim_complaint_theme dt ON dt.theme_id = t.theme_id
WHERE c.customer_status = 'Churned'
GROUP BY dt.theme_name
ORDER BY ticket_count DESC;

-- 6c. Tickets filed in the 90 days before churn (proximity-to-churn signal)
SELECT
    COUNT(DISTINCT t.customer_id) AS customers_with_pre_churn_tickets,
    COUNT(t.ticket_id) AS tickets_in_last_90_days
FROM fact_support_tickets t
JOIN dim_customers c ON c.customer_id = t.customer_id
WHERE c.customer_status = 'Churned'
  AND t.ticket_date BETWEEN c.churn_date - INTERVAL '90 days' AND c.churn_date;


-- ============================================================================
-- 7. PAYMENT FAILURE TIMING
-- Business Question: Do payment failures precede churn, and how close to
-- the cancellation date do they typically occur?
-- Insight: Payment failures are a strong, actionable early-warning signal —
-- if failures cluster right before churn, dunning/retry improvements could
-- directly reduce churn.
-- ============================================================================

-- 7a. Payment failure rate: churned vs retained customers
SELECT
    c.customer_status,
    COUNT(p.payment_id) AS total_attempts,
    SUM(CASE WHEN p.status = 'Failed' THEN 1 ELSE 0 END) AS failed_attempts,
    ROUND(
        100.0 * SUM(CASE WHEN p.status = 'Failed' THEN 1 ELSE 0 END) / COUNT(p.payment_id), 2
    ) AS failure_rate_pct
FROM fact_payment_attempts p
JOIN customer_churn_clean c ON c.customer_id = p.customer_id
GROUP BY c.customer_status;

-- 7b. Days between last payment failure and churn date
SELECT
    c.customer_id,
    MAX(p.payment_date) AS last_failed_payment_date,
    c.churn_date,
    (c.churn_date - MAX(p.payment_date)) AS days_between_failure_and_churn
FROM fact_payment_attempts p
JOIN dim_customers c ON c.customer_id = p.customer_id
WHERE p.status = 'Failed'
  AND c.customer_status = 'Churned'
GROUP BY c.customer_id, c.churn_date
ORDER BY days_between_failure_and_churn;

-- 7c. % of churned customers who had at least one payment failure in their final 30 days
SELECT
    COUNT(DISTINCT c.customer_id) AS total_churned,
    COUNT(DISTINCT p.customer_id) AS churned_with_late_failure,
    ROUND(
        100.0 * COUNT(DISTINCT p.customer_id) / COUNT(DISTINCT c.customer_id), 2
    ) AS pct_churned_with_late_payment_failure
FROM dim_customers c
LEFT JOIN fact_payment_attempts p
    ON p.customer_id = c.customer_id
    AND p.status = 'Failed'
    AND p.payment_date BETWEEN c.churn_date - INTERVAL '30 days' AND c.churn_date
WHERE c.customer_status = 'Churned';


-- ============================================================================
-- 8. CUSTOMER SATISFACTION (CSAT) & NET PROMOTER SCORE (NPS) ANALYSIS
-- Business Question: Do CSAT and NPS survey responses show warning signs
-- before churn?
-- Insight: Validates whether "soft" signals (satisfaction/loyalty scores)
-- align with "hard" behavioral signals (usage drop, tickets, payment issues) —
-- and whether low CSAT/NPS scores could serve as an early churn flag.
-- ============================================================================

-- 8a. Average CSAT & NPS scores: churned vs retained
SELECT
    c.customer_status,
    COUNT(s.survey_id) AS survey_responses,
    ROUND(AVG(s.csat_score), 2) AS avg_csat_score,
    ROUND(AVG(s.nps_score), 2) AS avg_nps_score
FROM fact_surveys s
JOIN customer_churn_clean c ON c.customer_id = s.customer_id
GROUP BY c.customer_status;


-- 8b. Survey response breakdown among churned customers
SELECT
    s.survey_response,
    COUNT(*) AS responses,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_churned_responses
FROM fact_surveys s
JOIN customer_churn_clean c ON c.customer_id = s.customer_id
WHERE c.customer_status = 'Churned'
GROUP BY s.survey_response
ORDER BY responses DESC;


-- 8c. Most recent survey before churn — checks how far in advance
-- dissatisfaction was signaled
SELECT
    c.customer_id,
    MAX(s.survey_date) AS last_survey_date,
    c.churn_date,
    (c.churn_date - MAX(s.survey_date)) AS days_between_survey_and_churn
FROM fact_surveys s
JOIN dim_customers c ON c.customer_id = s.customer_id
WHERE c.customer_status = 'Churned'
GROUP BY c.customer_id, c.churn_date
ORDER BY days_between_survey_and_churn;



-- ============================================================================
-- END OF EDA SCRIPT
-- ============================================================================