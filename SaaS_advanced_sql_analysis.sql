/* ============================================================================
   SAAS CUSTOMER CHURN PREDICTION PROJECT
   Advanced SQL Analysis (Stage 9) — PostgreSQL Query Set
   Answers all 30 Product-Driven Business Questions (Section 4, Project Brief)
   using window functions, CTEs, and set-based comparison logic.

   Tables referenced (12-table schema):
   dim_customers, dim_date, dim_complaint_theme, fact_usage_monthly,
   fact_engagement_monthly, fact_customer_monthly_snapshot,
   fact_payment_attempts, fact_support_tickets, fact_surveys,
   fact_churn_predictions, customer_churn_raw, customer_churn_clean
   Database:** PostgreSQL, 11 tables (schemas as supplied)
   Scope: Production-ready queries answering all product-driven business questions, 
   organized descriptive → diagnostic → risk → predictive → prescriptive

   
============================================================================ */

/* ======================================================

   4.1 Descriptive Analytics — "What is happening?"
  
   ======================================================= */
 

/* ==========================================================================================
   Q1. What is the overall churn rate, and how has it trended over time (monthly/quarterly)? 
   ==========================================================================================  */
-- 1a. Overall churn rate 
SELECT
    COUNT(*) FILTER (WHERE customer_status = 'Churned') AS churned_customers,
    COUNT(*) AS total_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE customer_status = 'Churned') / COUNT(*),
        2
    ) AS churn_rate_pct
FROM customer_churn_clean;

-- Both Churned and Active Customers count.
SELECT customer_status, COUNT(*) 
FROM customer_churn_clean 
GROUP BY customer_status;

-- 1b. how has it trended over time (monthly/quarterly)? 
WITH monthly_status AS (
    SELECT
        snapshot_month,
        DATE_TRUNC('quarter', snapshot_month)::date AS quarter_start,
        COUNT(*) AS total_customers,
        COUNT(*) FILTER (WHERE customer_status = 'Churned') AS churned_customers
    FROM fact_customer_monthly_snapshot
    GROUP BY snapshot_month
)
SELECT
    snapshot_month,
    quarter_start,
    total_customers,
    churned_customers,
    ROUND(churned_customers::numeric / NULLIF(total_customers, 0) * 100, 2) AS monthly_churn_rate_pct,
    ROUND(
        AVG(churned_customers::numeric / NULLIF(total_customers, 0) * 100)
            OVER (ORDER BY snapshot_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2
    ) AS churn_rate_3mo_moving_avg,
    ROUND(
        (churned_customers::numeric / NULLIF(total_customers, 0) * 100)
        - LAG(churned_customers::numeric / NULLIF(total_customers, 0) * 100) OVER (ORDER BY snapshot_month), 2
    ) AS mom_change_pp
FROM monthly_status
ORDER BY snapshot_month;


/* ==========================================================================================
   Q2. How is the customer base distributed by customer_segment, gender, city, and country? 
   ============================================================================================  */
SELECT
    customer_segment,
    gender,
    country,
    city,
    COUNT(*) AS customer_count,
    ROUND(COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS pct_of_total_base
FROM customer_churn_clean
GROUP BY GROUPING SETS (
    (customer_segment),
    (gender),
    (country),
    (country, city)
)
ORDER BY customer_segment NULLS LAST, gender NULLS LAST, country NULLS LAST, pct_of_total_base DESC;


/* ======================================================
   Q3. What does ARPU look like across segments? 
   ======================================================= */

SELECT
    customer_segment,
    COUNT(*) AS customer_count,
    ROUND(AVG(arpu), 2) AS avg_arpu,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arpu)::numeric, 2) AS median_arpu,
    ROUND(STDDEV(arpu), 2) AS arpu_stddev,
    ROUND(MIN(arpu), 2) AS min_arpu,
    ROUND(MAX(arpu), 2) AS max_arpu,
    RANK() OVER (ORDER BY AVG(arpu) DESC) AS segment_arpu_rank
FROM customer_churn_clean
GROUP BY customer_segment
ORDER BY avg_arpu DESC;


/* ==================================================================================================================
   Q4. What are average engagement scores, support ticket volumes, and payment failure rates across the customer base? 
   ===================================================================================================================  */
SELECT
    ROUND(AVG(engagement_score), 2) AS avg_engagement_score,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY engagement_score)::numeric, 2) AS median_engagement_score,
    ROUND(AVG(support_tickets), 2) AS avg_support_tickets,
    ROUND(AVG(payment_failures), 2) AS avg_payment_failures,
    ROUND(
        COUNT(*) FILTER (WHERE payment_failures > 0)::numeric / NULLIF(COUNT(*), 0) * 100, 2
    ) AS pct_customers_with_any_failure
FROM customer_churn_clean;

-- **Follow-up — same metrics split by churn status (sets up Section 4.2):**
SELECT
    churn,
    ROUND(AVG(engagement_score), 2) AS avg_engagement_score,
    ROUND(AVG(support_tickets), 2) AS avg_support_tickets,
    ROUND(AVG(payment_failures), 2) AS avg_payment_failures
FROM customer_churn_clean
GROUP BY churn;


/* ===================================================================
   Q5. What is the distribution of customer tenure at the point of churn?
   =================================================================== */
SELECT
    tenure_band,
    COUNT(*) AS churned_customers,
    ROUND(COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS pct_of_all_churn,
    ROUND(SUM(COUNT(*)) OVER (ORDER BY MIN(tenure_at_churn)) / SUM(COUNT(*)) OVER () * 100, 2) AS cumulative_pct
FROM customer_churn_clean
WHERE churn = 1
GROUP BY tenure_band
ORDER BY MIN(tenure_at_churn);


/* ==========================================================================
   Q6. What proportion of revenue is concentrated in which customer segments?
   ========================================================================== */
WITH segment_revenue AS (
    SELECT
        customer_segment,
        SUM(total_revenue) AS segment_revenue
    FROM customer_churn_clean
    GROUP BY customer_segment
)
SELECT
    customer_segment,
    segment_revenue,
    ROUND(segment_revenue / SUM(segment_revenue) OVER () * 100, 2) AS pct_of_total_revenue,
    ROUND(
        SUM(segment_revenue) OVER (ORDER BY segment_revenue DESC) / SUM(segment_revenue) OVER () * 100, 2
    ) AS cumulative_pct_of_revenue,
    RANK() OVER (ORDER BY segment_revenue DESC) AS revenue_rank
FROM segment_revenue
ORDER BY segment_revenue DESC;


/* =================================================

   4.2 Diagnostic Analytics — "Why is it happening?"

   ================================================= */

/* ==========================================================================================
   Q7. Why do churned and retained customers show near-identical ARPU — what does this rule out?
   ============================================================================================ */
SELECT
    churn,
    COUNT(*) AS customer_count,
    ROUND(AVG(arpu), 2) AS avg_arpu,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arpu)::numeric, 2) AS median_arpu,
    ROUND(STDDEV(arpu), 2) AS arpu_stddev,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arpu)::numeric - AVG(arpu)), 2
    ) AS median_minus_mean_skew_check
FROM customer_churn_clean
GROUP BY churn;


/* ======================================================================================================================
   Q8. Is there a relationship between customer ARPU, pricing, and churn — can spending level identify at-risk customers?
   =====================================================================================================================*/
WITH arpu_buckets AS (
    SELECT
        customer_id,
        churn,
        contract_type,
        arpu,
        NTILE(5) OVER (ORDER BY arpu) AS arpu_quintile
    FROM customer_churn_clean
)
SELECT
    arpu_quintile,
    MIN(arpu) AS min_arpu,
    MAX(arpu) AS max_arpu,
    COUNT(*) AS total_customers,
    COUNT(*) FILTER (WHERE churn = 1) AS churned_customers,
    ROUND(COUNT(*) FILTER (WHERE churn = 1)::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS churn_rate_pct
FROM arpu_buckets
GROUP BY arpu_quintile
ORDER BY arpu_quintile;


-- ARPU Comparison by Churn Status
SELECT
    churn,
    COUNT(*) AS customer_count,
    ROUND(AVG(monthly_fee)::numeric, 2) AS arpu,
    ROUND(STDDEV(monthly_fee)::numeric, 2) AS arpu_stddev,
    ROUND(MIN(monthly_fee)::numeric, 2) AS arpu_min,
    ROUND(MAX(monthly_fee)::numeric, 2) AS arpu_max,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY monthly_fee)::numeric, 2) AS arpu_median
FROM customer_churn_clean
GROUP BY churn;


-- Churn Rate by ARPU Segment
SELECT
    CASE
        WHEN monthly_fee < 20 THEN '1. Low ($0-19.99)'
        WHEN monthly_fee < 40 THEN '2. Mid-Low ($20-39.99)'
        WHEN monthly_fee < 60 THEN '3. Mid ($40-59.99)'
        WHEN monthly_fee < 80 THEN '4. Mid-High ($60-79.99)'
        ELSE '5. High ($80+)'
    END AS arpu_bucket,
    COUNT(*) AS total_customers,
    COUNT(*) FILTER (WHERE churn = 1) AS churned_customers,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    ) AS churn_rate_pct,
    ROUND(AVG(monthly_fee)::numeric, 2) AS avg_arpu_in_bucket
FROM customer_churn_clean
GROUP BY arpu_bucket
ORDER BY arpu_bucket;


/* ======================================================================================================
   Q9. Why is churn concentrated in the first six months — what onboarding/engagement failures explain this?
   ======================================================================================================= */
SELECT
    tenure_band,
    COUNT(*) FILTER (WHERE churn = 1) AS churned,
    ROUND(AVG(engagement_score) FILTER (WHERE churn = 1), 2) AS avg_engagement_score_churned,
    ROUND(AVG(monthly_logins) FILTER (WHERE churn = 1), 2) AS avg_monthly_logins_churned,
    ROUND(AVG(features_used) FILTER (WHERE churn = 1), 2) AS avg_features_used_churned,
    ROUND(AVG(support_tickets) FILTER (WHERE churn = 1), 2) AS avg_tickets_churned,
    ROUND(AVG(csat_score) FILTER (WHERE churn = 1), 2) AS avg_csat_churned
FROM customer_churn_clean
WHERE tenure_band IN (SELECT tenure_band FROM customer_churn_clean WHERE churn = 1 GROUP BY tenure_band ORDER BY MIN(tenure_at_churn) LIMIT 2)
GROUP BY tenure_band
ORDER BY MIN(tenure_at_churn);


/* =====================================================================================
   Q10. Which support ticket types/complaint themes correlate most strongly with churn?
   ====================================================================================== */
WITH ticket_churn AS (
    SELECT
        t.theme_id,
        th.theme_name,
        th.theme_group,
        c.customer_id,
        c.churn
    FROM fact_support_tickets t
    JOIN dim_complaint_theme th ON t.theme_id = th.theme_id
    JOIN customer_churn_clean c ON t.customer_id = c.customer_id
)
SELECT
    theme_group,
    theme_name,
    COUNT(DISTINCT customer_id) AS customers_with_ticket_type,
    COUNT(DISTINCT customer_id) FILTER (WHERE churn = 1) AS of_which_churned,
    ROUND(
        COUNT(DISTINCT customer_id) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(DISTINCT customer_id), 0) * 100, 2
    ) AS churn_rate_among_ticket_holders,
    RANK() OVER (ORDER BY COUNT(DISTINCT customer_id) FILTER (WHERE churn = 1)::numeric / NULLIF(COUNT(DISTINCT customer_id), 0) DESC) AS risk_rank
FROM ticket_churn
GROUP BY theme_group, theme_name
ORDER BY churn_rate_among_ticket_holders DESC;


/* =================================================================================
   Q11. Do payment failures precede churn, or are they a symptom of disengagement?
   ================================================================================= */
WITH failure_timing AS (
    SELECT
        p.customer_id,
        p.payment_date,
        d.churn_date,
        (d.churn_date - p.payment_date) AS days_before_churn
    FROM fact_payment_attempts p
    JOIN dim_customers d ON p.customer_id = d.customer_id
    WHERE p.status = 'Failed'
      AND d.churn = 1
      AND d.churn_date IS NOT NULL
)
SELECT
    CASE
        WHEN days_before_churn <= 30 THEN '1. Within last 30 days'
        WHEN days_before_churn <= 90 THEN '2. 31-90 days before'
        WHEN days_before_churn <= 180 THEN '3. 91-180 days before'
        ELSE '4. 180+ days before'
    END AS failure_window,
    COUNT(*) AS failed_payment_count,
    COUNT(DISTINCT customer_id) AS distinct_customers,
    ROUND(AVG(days_before_churn), 1) AS avg_days_before_churn
FROM failure_timing
WHERE days_before_churn >= 0
GROUP BY failure_window
ORDER BY failure_window;


-- b. payment failures contribute significantly to customer churn?
SELECT
    c.customer_status,
    COUNT(*) AS total_payment_attempts,
    COUNT(*) FILTER (WHERE pa.status = 'Failed') AS failed_attempts,
    ROUND(
        COUNT(*) FILTER (WHERE pa.status = 'Failed')::numeric / NULLIF(COUNT(*), 0) * 100, 2
    ) AS failure_rate_pct,
    COUNT(DISTINCT c.customer_id) AS distinct_customers,
    COUNT(DISTINCT pa.customer_id) FILTER (WHERE pa.status = 'Failed') AS customers_with_at_least_one_failure,
    ROUND(
        COUNT(DISTINCT pa.customer_id) FILTER (WHERE pa.status = 'Failed')::numeric
        / NULLIF(COUNT(DISTINCT c.customer_id), 0) * 100, 2
    ) AS pct_customers_with_failure
FROM customer_churn_clean c
JOIN fact_payment_attempts pa ON c.customer_id = pa.customer_id
GROUP BY c.customer_status
ORDER BY c.customer_status;


/* ========================================================================== 
   Q12. What factors differentiate churned customers from retained customers, and 
   which of these differences are most significant?"   
   ===========================================================================  */   
WITH payment_failure_summary AS (
    SELECT
        c.customer_status,
        ROUND(
            COUNT(DISTINCT pa.customer_id) FILTER (WHERE pa.status = 'Failed')::numeric
            / NULLIF(COUNT(DISTINCT c.customer_id), 0) * 100, 2
        ) AS pct_customers_with_failure
    FROM customer_churn_clean c
    JOIN fact_payment_attempts pa ON c.customer_id = pa.customer_id
    GROUP BY c.customer_status
)
SELECT *
FROM (
    SELECT
        'ARPU (price)' AS driver,
        ROUND(AVG(arpu) FILTER (WHERE churn = 1), 2) AS avg_value_churned,
        ROUND(AVG(arpu) FILTER (WHERE churn = 0), 2) AS avg_value_retained,
        ROUND(AVG(arpu) FILTER (WHERE churn = 1) - AVG(arpu) FILTER (WHERE churn = 0), 2) AS gap
    FROM customer_churn_clean
    UNION ALL
    SELECT
        'Engagement score',
        ROUND(AVG(engagement_score) FILTER (WHERE churn = 1), 2),
        ROUND(AVG(engagement_score) FILTER (WHERE churn = 0), 2),
        ROUND(AVG(engagement_score) FILTER (WHERE churn = 1) - AVG(engagement_score) FILTER (WHERE churn = 0), 2)
    FROM customer_churn_clean
    UNION ALL
    SELECT
        'Support tickets',
        ROUND(AVG(support_tickets) FILTER (WHERE churn = 1), 2),
        ROUND(AVG(support_tickets) FILTER (WHERE churn = 0), 2),
        ROUND(AVG(support_tickets) FILTER (WHERE churn = 1) - AVG(support_tickets) FILTER (WHERE churn = 0), 2)
    FROM customer_churn_clean
    UNION ALL
    SELECT
        'CSAT score',
        ROUND(AVG(csat_score) FILTER (WHERE churn = 1), 2),
        ROUND(AVG(csat_score) FILTER (WHERE churn = 0), 2),
        ROUND(AVG(csat_score) FILTER (WHERE churn = 1) - AVG(csat_score) FILTER (WHERE churn = 0), 2)
    FROM customer_churn_clean
    UNION ALL
    SELECT
        '% customers with a failed payment',
        (SELECT pct_customers_with_failure FROM payment_failure_summary WHERE customer_status = 'Churned'),
        (SELECT pct_customers_with_failure FROM payment_failure_summary WHERE customer_status = 'Active'),
        (SELECT pct_customers_with_failure FROM payment_failure_summary WHERE customer_status = 'Churned')
            - (SELECT pct_customers_with_failure FROM payment_failure_summary WHERE customer_status = 'Active')
) driver_comparison
ORDER BY ABS(gap) DESC;



/* ==============================================================================
   Q13. Is there a relationship between engagement score decline and churn timing?
   =============================================================================== */
WITH engagement_trend AS (
    SELECT
        customer_id,
        snapshot_month,
        engagement_score_current,
        engagement_score_trend,
        customer_status,
        LAG(engagement_score_current, 3) OVER (PARTITION BY customer_id ORDER BY snapshot_month) AS engagement_3mo_ago
    FROM fact_customer_monthly_snapshot
)
SELECT
    customer_status,
    ROUND(AVG(engagement_score_current), 2) AS avg_current_engagement,
    ROUND(AVG(engagement_3mo_ago), 2) AS avg_engagement_3mo_earlier,
    ROUND(AVG(engagement_score_current - engagement_3mo_ago), 2) AS avg_3mo_change,
    ROUND(AVG(engagement_score_trend), 2) AS avg_trend_field
FROM engagement_trend
WHERE engagement_3mo_ago IS NOT NULL
GROUP BY customer_status;


/* ============================================================================================================
   Q14. How do churned customers' usage patterns differ from retained customers' in months leading up to churn?
   ============================================================================================================= */
WITH usage_ranked AS (
    SELECT
        u.customer_id,
        u.usage_month,
        u.monthly_logins,
        u.features_used,
        u.last_login_days_ago,
        d.churn,
        d.churn_date,
        ROW_NUMBER() OVER (
            PARTITION BY u.customer_id ORDER BY u.usage_month DESC
        ) AS months_back
    FROM fact_usage_monthly u
    JOIN dim_customers d ON u.customer_id = d.customer_id
    WHERE d.churn_date IS NULL OR u.usage_month <= d.churn_date
)
SELECT
    churn,
    months_back,
    ROUND(AVG(monthly_logins), 2) AS avg_monthly_logins,
    ROUND(AVG(features_used), 2) AS avg_features_used,
    ROUND(AVG(last_login_days_ago), 2) AS avg_last_login_days_ago
FROM usage_ranked
WHERE months_back <= 3
GROUP BY churn, months_back
ORDER BY churn, months_back;


/* =======================================================================================================
   Q15. Are there country-level or city-level differences in ticket volume, complaint type, or churn rate?
   ======================================================================================================== */
SELECT
    c.country,
    c.city,
    COUNT(DISTINCT c.customer_id) AS customer_count,
    COUNT(t.ticket_id) AS total_tickets,
    ROUND(COUNT(t.ticket_id)::numeric / NULLIF(COUNT(DISTINCT c.customer_id), 0), 2) AS tickets_per_customer,
    ROUND(
        COUNT(DISTINCT c.customer_id) FILTER (WHERE c.churn = 1)::numeric
        / NULLIF(COUNT(DISTINCT c.customer_id), 0) * 100, 2
    ) AS churn_rate_pct,
    MODE() WITHIN GROUP (ORDER BY t.complaint_type) AS most_common_complaint_type
FROM customer_churn_clean c
LEFT JOIN fact_support_tickets t ON c.customer_id = t.customer_id
GROUP BY c.country, c.city
HAVING COUNT(DISTINCT c.customer_id) >= 20
ORDER BY churn_rate_pct DESC;


/* ===================================================================

   4.3 Risk Analysis — "Where is the exposure, and how severe is it?"
   
   ==================================================================== */

/* ========================================================================================
   Q16. Which active customers currently show the highest composite behavioral risk scores?
   ========================================================================================= */
WITH latest_snapshot AS (
    SELECT DISTINCT ON (customer_id)
        customer_id,
        snapshot_month,
        composite_risk_score,
        risk_tier,
        customer_status,
        engagement_score_current,
        ticket_volume_score,
        payment_failure_score
    FROM fact_customer_monthly_snapshot
    ORDER BY customer_id, snapshot_month DESC
)
SELECT
    customer_id,
    snapshot_month,
    composite_risk_score,
    risk_tier,
    engagement_score_current,
    ticket_volume_score,
    payment_failure_score,
    RANK() OVER (ORDER BY composite_risk_score DESC) AS risk_rank
FROM latest_snapshot
WHERE customer_status = 'Active'
ORDER BY composite_risk_score DESC
LIMIT 100;


/* =====================================================================================
   Q17. What percentage of current MRR sits with "high risk" accounts on the watchlist?
   ===================================================================================== */
WITH latest_snapshot AS (
    SELECT DISTINCT ON (customer_id)
        customer_id, risk_tier, customer_status
    FROM fact_customer_monthly_snapshot
    ORDER BY customer_id, snapshot_month DESC
)
SELECT
    ls.risk_tier,
    COUNT(*) AS active_customers,
    SUM(c.monthly_fee) AS mrr_in_tier,
    ROUND(SUM(c.monthly_fee) / SUM(SUM(c.monthly_fee)) OVER () * 100, 2) AS pct_of_total_mrr
FROM latest_snapshot ls
JOIN customer_churn_clean c ON ls.customer_id = c.customer_id
WHERE ls.customer_status = 'Active'
GROUP BY ls.risk_tier
ORDER BY pct_of_total_mrr DESC;


/* ==========================================================================================
   Q18. Which tenure milestones (30/60/90/180 days) represent the highest-risk windows, and 
        how many active customers currently sit there?
   =========================================================================================== */
WITH active_tenure_days AS (
    SELECT
        customer_id,
        tenure_months * 30 AS approx_tenure_days,
        risk_tier
    FROM customer_churn_clean
    WHERE customer_status = 'Active'
),
milestone_windows AS (
    SELECT customer_id, approx_tenure_days, risk_tier,
        CASE
            WHEN approx_tenure_days BETWEEN 0 AND 30 THEN '0-30 days'
            WHEN approx_tenure_days BETWEEN 31 AND 60 THEN '31-60 days'
            WHEN approx_tenure_days BETWEEN 61 AND 90 THEN '61-90 days'
            WHEN approx_tenure_days BETWEEN 91 AND 180 THEN '91-180 days'
            ELSE '180+ days'
        END AS tenure_window
    FROM active_tenure_days
)
SELECT
    tenure_window,
    COUNT(*) AS active_customers_in_window,
    COUNT(*) FILTER (WHERE risk_tier = 'High') AS high_risk_count,
    ROUND(COUNT(*) FILTER (WHERE risk_tier = 'High')::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS pct_high_risk
FROM milestone_windows
GROUP BY tenure_window
ORDER BY MIN(approx_tenure_days);


/* ============================================================================================
   Q19. What is the revenue-at-risk if the current high-risk cohort churns at historical rates?
   ============================================================================================= */
WITH high_risk_active AS (
    SELECT customer_id, monthly_fee, total_revenue
    FROM customer_churn_clean
    WHERE customer_status = 'Active' AND risk_tier = 'High'
),
historical_churn_rate AS (
    SELECT
        ROUND(COUNT(*) FILTER (WHERE churn = 1)::numeric / NULLIF(COUNT(*), 0), 4) AS overall_churn_rate,
        ROUND(
            COUNT(*) FILTER (WHERE churn = 1 AND risk_tier = 'High')::numeric
            / NULLIF(COUNT(*) FILTER (WHERE risk_tier = 'High'), 0), 4
        ) AS high_risk_historical_churn_rate
    FROM customer_churn_clean
)
SELECT
    (SELECT COUNT(*) FROM high_risk_active) AS high_risk_active_customers,
    (SELECT SUM(monthly_fee) FROM high_risk_active) AS current_mrr_at_risk,
    h.high_risk_historical_churn_rate,
    ROUND((SELECT SUM(monthly_fee) FROM high_risk_active) * h.high_risk_historical_churn_rate, 2) AS expected_mrr_loss_next_period,
    ROUND((SELECT SUM(monthly_fee) FROM high_risk_active) * h.high_risk_historical_churn_rate * 12, 2) AS expected_annualized_revenue_loss
FROM historical_churn_rate h;


/* ==================================================================================
   Q18. Are there specific segments structurally over-represented in risk exposure?
   ================================================================================== */
SELECT
    customer_segment,
    contract_type,
    country,
    COUNT(*) AS active_customers,
    COUNT(*) FILTER (WHERE risk_tier = 'High') AS high_risk_customers,
    ROUND(COUNT(*) FILTER (WHERE risk_tier = 'High')::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS pct_high_risk,
    ROUND(
        COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2
    ) AS pct_of_active_base,
    ROUND(
        COUNT(*) FILTER (WHERE risk_tier = 'High')::numeric / SUM(COUNT(*) FILTER (WHERE risk_tier = 'High')) OVER () * 100, 2
    ) AS pct_of_all_high_risk
FROM customer_churn_clean
WHERE customer_status = 'Active'
GROUP BY customer_segment, contract_type, country
HAVING COUNT(*) >= 15
ORDER BY pct_high_risk DESC;


/* =====================================================================
   Q21. How concentrated is churn risk — broad and even, or clustered?
   ===================================================================== */
WITH risk_distribution AS (
    SELECT
        customer_id,
        composite_risk_score,
        NTILE(10) OVER (ORDER BY composite_risk_score DESC) AS risk_decile
    FROM fact_customer_monthly_snapshot
    WHERE snapshot_month = (SELECT MAX(snapshot_month) FROM fact_customer_monthly_snapshot)
      AND customer_status = 'Active'
)
SELECT
    risk_decile,
    COUNT(*) AS customers_in_decile,
    ROUND(SUM(composite_risk_score), 2) AS total_risk_score_in_decile,
    ROUND(
        SUM(composite_risk_score) / SUM(SUM(composite_risk_score)) OVER () * 100, 2
    ) AS pct_of_total_risk_score,
    ROUND(
        SUM(SUM(composite_risk_score)) OVER (ORDER BY risk_decile) / SUM(SUM(composite_risk_score)) OVER () * 100, 2
    ) AS cumulative_pct_of_risk
FROM risk_distribution
GROUP BY risk_decile
ORDER BY risk_decile;


/* ===========================================================
   4.4 Predictive Analytics — "What is likely to happen next?"
   =========================================================== */

-- ("Descriptive/diagnostic use of the existing `fact_churn_predictions` model outputs — 
-- no new model is trained here, per the available schema."")

/* ================================================================================
   Q22. Which active customers are most likely to churn in the next 30/60/90 days?
   ================================================================================ */
WITH latest_prediction AS (
    SELECT DISTINCT ON (fp.customer_id)
        fp.customer_id,
        fp.scored_at,
        fp.churn_probability_30d,
        fp.churn_probability_60d,
        fp.churn_probability_90d,
        fp.predicted_risk_tier,
        c.customer_status,
        c.monthly_fee
    FROM fact_churn_predictions fp
    JOIN customer_churn_clean c ON fp.customer_id = c.customer_id
    ORDER BY fp.customer_id, fp.scored_at DESC
)
SELECT
    customer_id,
    churn_probability_30d,
    churn_probability_60d,
    churn_probability_90d,
    predicted_risk_tier,
    monthly_fee,
    RANK() OVER (ORDER BY churn_probability_90d DESC) AS urgency_rank
FROM latest_prediction
WHERE customer_status = 'Active'
ORDER BY churn_probability_90d DESC
LIMIT 200;


select *
from fact_churn_predictions;


/* =========================================================================
   Q23. What are the leading indicators (features) that best predict churn?
   ========================================================================== */
SELECT
    feature_data.key AS feature_name,
    COUNT(*) AS times_appeared_as_top_feature,
    ROUND(AVG((feature_data.value)::numeric), 4) AS avg_feature_importance
FROM fact_churn_predictions fp,
    jsonb_each_text(fp.top_features) AS feature_data(key, value)
GROUP BY feature_data.key
ORDER BY times_appeared_as_top_feature DESC, avg_feature_importance DESC;


/* ==========================================================================================
   Q24. What churn probability score can be assigned to each active customer, and 
        how does it rank vs. the composite risk score?
   ========================================================================================= */
WITH latest_prediction AS (
    SELECT DISTINCT ON (customer_id) customer_id, churn_probability_90d
    FROM fact_churn_predictions
    ORDER BY customer_id, scored_at DESC
),
latest_snapshot AS (
    SELECT DISTINCT ON (customer_id) customer_id, composite_risk_score, customer_status
    FROM fact_customer_monthly_snapshot
    ORDER BY customer_id, snapshot_month DESC
)
SELECT
    s.customer_id,
    p.churn_probability_90d,
    RANK() OVER (ORDER BY p.churn_probability_90d DESC) AS ml_probability_rank,
    s.composite_risk_score,
    RANK() OVER (ORDER BY s.composite_risk_score DESC) AS composite_score_rank,
    RANK() OVER (ORDER BY p.churn_probability_90d DESC) - RANK() OVER (ORDER BY s.composite_risk_score DESC) AS rank_gap
FROM latest_snapshot s
JOIN latest_prediction p ON s.customer_id = p.customer_id
WHERE s.customer_status = 'Active'
ORDER BY p.churn_probability_90d DESC
LIMIT 100;


-- Worth checking directly:
SELECT MIN(composite_risk_score), MAX(composite_risk_score), AVG(composite_risk_score),
       COUNT(DISTINCT composite_risk_score) AS distinct_values,
       COUNT(*) AS total_rows
FROM fact_customer_monthly_snapshot;

/* ========================================================================================
   Q25. How will churn rate trend over the next 1-2 quarters if current patterns continue?
   ======================================================================================== */
WITH monthly_churn AS (
    SELECT
        snapshot_month,
        ROUND(COUNT(*) FILTER (WHERE customer_status = 'Churned')::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS churn_rate_pct
    FROM fact_customer_monthly_snapshot
    GROUP BY snapshot_month
),
trend_calc AS (
    SELECT
        snapshot_month,
        churn_rate_pct,
        ROW_NUMBER() OVER (ORDER BY snapshot_month) AS month_index
    FROM monthly_churn
)
SELECT
    REGR_SLOPE(churn_rate_pct, month_index) AS monthly_trend_slope_pp,
    REGR_INTERCEPT(churn_rate_pct, month_index) AS trend_intercept,
    ROUND(
        (REGR_INTERCEPT(churn_rate_pct, month_index) + REGR_SLOPE(churn_rate_pct, month_index) * (MAX(month_index) + 3))::numeric, 2
    ) AS projected_churn_rate_next_quarter,
    ROUND(
        (REGR_INTERCEPT(churn_rate_pct, month_index) + REGR_SLOPE(churn_rate_pct, month_index) * (MAX(month_index) + 6))::numeric, 2
    ) AS projected_churn_rate_in_2_quarters
FROM trend_calc;


/* ===================================================================================
   Q26. Which customer segments are predicted to have the highest future churn rates — 
      does this align with diagnostic findings?
   ====================================================================================  */
WITH latest_prediction AS (
    SELECT DISTINCT ON (fp.customer_id)
        fp.customer_id, fp.churn_probability_90d
    FROM fact_churn_predictions fp
    ORDER BY fp.customer_id, fp.scored_at DESC
)
SELECT
    c.customer_segment,
    c.contract_type,
    COUNT(*) AS customer_count,
    ROUND(AVG(p.churn_probability_90d), 4) AS avg_predicted_churn_prob_90d,
    ROUND(AVG(c.engagement_score), 2) AS avg_actual_engagement_score,
    RANK() OVER (ORDER BY AVG(p.churn_probability_90d) DESC) AS predicted_risk_rank
FROM customer_churn_clean c
JOIN latest_prediction p ON c.customer_id = p.customer_id
WHERE c.customer_status = 'Active'
GROUP BY c.customer_segment, c.contract_type
ORDER BY avg_predicted_churn_prob_90d DESC;


select *
from fact_churn_predictions;


/* =================================================================

   4.5 Prescriptive Analytics — "What should we do about it?"

   ================================================================= */

/* =====================================================================================================================
   Q27. Given churn is experience-driven rather than price-driven
   ====================================================================================================================== */
WITH driver_gaps AS (
    SELECT 'Engagement score' AS driver,
           'Customer Retention Engagement Programs' AS recommended_intervention,
           ROUND(AVG(engagement_score) FILTER (WHERE churn = 0)
               - AVG(engagement_score) FILTER (WHERE churn = 1), 2) AS raw_gap,
           ROUND(
               (AVG(engagement_score) FILTER (WHERE churn = 0) - AVG(engagement_score) FILTER (WHERE churn = 1))
               / NULLIF(AVG(engagement_score) FILTER (WHERE churn = 0), 0) * 100, 2
           ) AS pct_gap_vs_retained
    FROM customer_churn_clean
    UNION ALL
    SELECT 'CSAT score',
           'Proactive support outreach',
           ROUND(AVG(csat_score) FILTER (WHERE churn = 0) - AVG(csat_score) FILTER (WHERE churn = 1), 2),
           ROUND(
               (AVG(csat_score) FILTER (WHERE churn = 0) - AVG(csat_score) FILTER (WHERE churn = 1))
               / NULLIF(AVG(csat_score) FILTER (WHERE churn = 0), 0) * 100, 2
           )
    FROM customer_churn_clean
    UNION ALL
    SELECT 'Support tickets',
           'Proactive support outreach',
           ROUND(AVG(support_tickets) FILTER (WHERE churn = 1) - AVG(support_tickets) FILTER (WHERE churn = 0), 2),
           ROUND(
               (AVG(support_tickets) FILTER (WHERE churn = 1) - AVG(support_tickets) FILTER (WHERE churn = 0))
               / NULLIF(AVG(support_tickets) FILTER (WHERE churn = 0), 0) * 100, 2
           )
    FROM customer_churn_clean
    UNION ALL
    SELECT '% customers with a failed payment',
           'Reduce Billing Friction Through Dunning and Timely Card-Update Reminders',
           9.62,
           ROUND(9.62 / 38.18 * 100, 2)
)
SELECT
    driver,
    recommended_intervention,
    raw_gap,
    pct_gap_vs_retained,
    RANK() OVER (ORDER BY ABS(pct_gap_vs_retained) DESC) AS priority_rank
FROM driver_gaps
ORDER BY priority_rank;


/* ========================================================================================================
   Q28. What intervention should trigger for customers crossing into the first-six-months high-risk window?
   ======================================================================================================== */
WITH high_risk_window AS (
    SELECT
        c.customer_id,
        c.tenure_months,
        c.engagement_score,
        c.csat_score,
        c.arpu,
        CASE WHEN pa_fail.customer_id IS NOT NULL THEN 1 ELSE 0 END AS has_failed_payment
    FROM customer_churn_clean c
    LEFT JOIN (
        SELECT DISTINCT customer_id
        FROM fact_payment_attempts
        WHERE status = 'Failed'
    ) pa_fail ON c.customer_id = pa_fail.customer_id
    WHERE c.customer_status = 'Active'
      AND c.tenure_months <= 6
)
SELECT
    customer_id,
    tenure_months,
    engagement_score,
    csat_score,
    has_failed_payment,
    CASE
        WHEN has_failed_payment = 1 THEN 'Trigger: Payment retry + card-update reminder'
        WHEN engagement_score < (SELECT AVG(engagement_score) FROM customer_churn_clean) THEN 'Trigger: Onboarding check-in / engagement nudge'
        WHEN csat_score < (SELECT AVG(csat_score) FROM customer_churn_clean) THEN 'Trigger: Proactive support outreach'
        ELSE 'Monitor: No acute risk factor detected'
    END AS recommended_intervention
FROM high_risk_window
ORDER BY tenure_months ASC;


/* ================================================================================================
   Q29. Which high-risk accounts should be prioritized for CS outreach given limited team capacity?
   ================================================================================================= */
WITH latest_prediction AS (
    SELECT DISTINCT ON (fp.customer_id)
        fp.customer_id,
        fp.churn_probability_90d,
        fp.predicted_risk_tier
    FROM fact_churn_predictions fp
    ORDER BY fp.customer_id, fp.scored_at DESC
),
scored_accounts AS (
    SELECT
        c.customer_id,
        c.arpu,
        c.engagement_score,
        c.csat_score,
        p.churn_probability_90d,
        p.predicted_risk_tier,
        ROUND((p.churn_probability_90d * c.arpu)::numeric, 2) AS expected_revenue_at_risk
    FROM customer_churn_clean c
    JOIN latest_prediction p ON c.customer_id = p.customer_id
    WHERE c.customer_status = 'Active'
)
SELECT
    customer_id,
    churn_probability_90d,
    predicted_risk_tier,
    arpu,
    expected_revenue_at_risk,
    RANK() OVER (ORDER BY expected_revenue_at_risk DESC) AS outreach_priority_rank
FROM scored_accounts
ORDER BY outreach_priority_rank
LIMIT 50;  -- adjust to match actual team capacity (e.g., outreach reps × accounts/week)


/* ===================================================================================================================
   Q30. What is the expected ROI/revenue-saved from intervening on the top N highest-risk accounts vs. broad campaigns?
   ==================================================================================================================== */
WITH latest_prediction AS (
    SELECT DISTINCT ON (fp.customer_id)
        fp.customer_id, fp.churn_probability_90d
    FROM fact_churn_predictions fp
    ORDER BY fp.customer_id, fp.scored_at DESC
),
scored_accounts AS (
    SELECT
        c.customer_id,
        c.arpu,
        p.churn_probability_90d,
        ROUND((p.churn_probability_90d * c.arpu)::numeric, 2) AS expected_revenue_at_risk,
        RANK() OVER (ORDER BY p.churn_probability_90d * c.arpu DESC) AS risk_rank
    FROM customer_churn_clean c
    JOIN latest_prediction p ON c.customer_id = p.customer_id
    WHERE c.customer_status = 'Active'
),
-- Strategy A: Targeted outreach to top N highest-risk accounts
targeted_strategy AS (
    SELECT
        'Targeted (Top 100 highest-risk)' AS strategy,
        COUNT(*) AS accounts_targeted,
        SUM(expected_revenue_at_risk) AS total_revenue_at_risk,
        100 AS assumed_cost_per_account,          -- ASSUMPTION: cost of a high-touch CS intervention
        0.35 AS assumed_success_rate               -- ASSUMPTION: % of interventions that prevent churn
    FROM scored_accounts
    WHERE risk_rank <= 100
),
-- Strategy B: Broad-based campaign (e.g., discount/email blast to all active customers)
broad_strategy AS (
    SELECT
        'Broad-based campaign (All active customers)' AS strategy,
        COUNT(*) AS accounts_targeted,
        SUM(expected_revenue_at_risk) AS total_revenue_at_risk,
        5 AS assumed_cost_per_account,             -- ASSUMPTION: cost of a low-touch email/discount campaign
        0.05 AS assumed_success_rate                -- ASSUMPTION: much lower success rate, spread thin
    FROM scored_accounts
)
SELECT
    strategy,
    accounts_targeted,
    total_revenue_at_risk,
    ROUND(total_revenue_at_risk * assumed_success_rate, 2) AS estimated_revenue_saved,
    accounts_targeted * assumed_cost_per_account AS estimated_campaign_cost,
    ROUND(
        (total_revenue_at_risk * assumed_success_rate - accounts_targeted * assumed_cost_per_account)
        / NULLIF(accounts_targeted * assumed_cost_per_account, 0), 2
    ) AS estimated_roi_multiple
FROM targeted_strategy
UNION ALL
SELECT
    strategy,
    accounts_targeted,
    total_revenue_at_risk,
    ROUND(total_revenue_at_risk * assumed_success_rate, 2),
    accounts_targeted * assumed_cost_per_account,
    ROUND(
        (total_revenue_at_risk * assumed_success_rate - accounts_targeted * assumed_cost_per_account)
        / NULLIF(accounts_targeted * assumed_cost_per_account, 0), 2
    )
FROM broad_strategy;


/* ================================================================================================
   Q31. Should complaint-type-specific playbooks be built, and which complaint themes justify them?
   ================================================================================================ */
WITH complaint_summary AS (
    SELECT
        dct.theme_name,
        COUNT(DISTINCT fst.customer_id) AS customers_affected,
        COUNT(*) AS total_tickets,
        COUNT(DISTINCT fst.customer_id) FILTER (WHERE c.churn = 1) AS churned_customers_affected,
        ROUND(
            COUNT(DISTINCT fst.customer_id) FILTER (WHERE c.churn = 1)::numeric
            / NULLIF(COUNT(DISTINCT fst.customer_id), 0) * 100, 2
        ) AS churn_rate_within_theme
    FROM fact_support_tickets fst
    JOIN dim_complaint_theme dct ON fst.theme_id = dct.theme_id
    JOIN customer_churn_clean c ON fst.customer_id = c.customer_id
    GROUP BY dct.theme_name
),
overall_churn_rate AS (
    SELECT ROUND(AVG(churn)::numeric * 100, 2) AS baseline_churn_rate
    FROM customer_churn_clean
)
SELECT
    cs.theme_name,
    cs.customers_affected,
    cs.total_tickets,
    cs.churned_customers_affected,
    cs.churn_rate_within_theme,
    ocr.baseline_churn_rate,
    ROUND(cs.churn_rate_within_theme - ocr.baseline_churn_rate, 2) AS churn_rate_lift_pp,
    CASE
        WHEN cs.customers_affected >= 100
             AND cs.churn_rate_within_theme > ocr.baseline_churn_rate * 1.3
        THEN 'Build dedicated playbook — high volume AND elevated churn risk'
        WHEN cs.churn_rate_within_theme > ocr.baseline_churn_rate * 1.3
        THEN 'Monitor — elevated churn risk but low volume, watch for growth'
        WHEN cs.customers_affected >= 100
        THEN 'Standard handling — high volume but not disproportionately churn-linked'
        ELSE 'No dedicated playbook needed'
    END AS recommendation
FROM complaint_summary cs
CROSS JOIN overall_churn_rate ocr
ORDER BY churn_rate_lift_pp DESC;


-- =====================================================================
-- Q32: What early-warning threshold should trigger an automated
--    retention workflow, and what should the workflow DO about it?
-- =====================================================================

-- The question is analytically framed. 
-- “When should we consider a customer sufficiently at risk of leaving, and what automated action should we take to try to retain them?”


WITH engagement_bins AS (
    SELECT
        width_bucket(engagement_score, 0, 100, 10) AS score_decile,
        COUNT(*) AS customers_in_bin,
        SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END) AS churned_in_bin,
        ROUND(
            100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        ) AS churn_rate_pct
    FROM customer_churn_clean
    WHERE engagement_score IS NOT NULL
    GROUP BY score_decile
),
overall_baseline AS (
    SELECT
        ROUND(
            100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        ) AS overall_churn_rate_pct
    FROM customer_churn_clean
),
engagement_threshold AS (
    SELECT MAX(score_decile) * 10 AS engagement_score_cutoff
    FROM engagement_bins, overall_baseline
    WHERE churn_rate_pct >= 1.5 * overall_churn_rate_pct
),
ticket_counts AS (
    SELECT
        c.customer_id,
        c.customer_status,
        COUNT(t.ticket_id) FILTER (
            WHERE t.ticket_date >= CURRENT_DATE - INTERVAL '90 days'
        ) AS tickets_90d
    FROM customer_churn_clean c
    LEFT JOIN fact_support_tickets t ON t.customer_id = c.customer_id
    GROUP BY c.customer_id, c.customer_status
),
ticket_bins AS (
    SELECT
        tickets_90d,
        COUNT(*) AS customers_in_bin,
        ROUND(
            100.0 * SUM(CASE WHEN customer_status = 'Churned' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        ) AS churn_rate_pct
    FROM ticket_counts
    GROUP BY tickets_90d
),
ticket_threshold AS (
    SELECT MIN(tickets_90d) AS ticket_count_cutoff
    FROM ticket_bins, overall_baseline
    WHERE churn_rate_pct >= 1.5 * overall_churn_rate_pct
      AND customers_in_bin >= 20
),
current_signals AS (
    SELECT
        c.customer_id,
        c.engagement_score,
        c.arpu,
        c.risk_tier,
        tc.tickets_90d,
        fp.churn_probability_90d,
        fp.predicted_risk_tier
    FROM customer_churn_clean c
    JOIN ticket_counts tc ON tc.customer_id = c.customer_id
    LEFT JOIN fact_churn_predictions fp ON fp.customer_id = c.customer_id
    WHERE c.customer_status = 'Active'
)
SELECT
    cs.customer_id,
    cs.engagement_score,
    cs.tickets_90d,
    cs.arpu,
    cs.churn_probability_90d,
    cs.predicted_risk_tier,
    et.engagement_score_cutoff,
    tt.ticket_count_cutoff,
    CASE
        WHEN cs.engagement_score <= et.engagement_score_cutoff
             AND cs.tickets_90d  >= tt.ticket_count_cutoff
            THEN 'Disengagement + Support Friction'
        WHEN cs.engagement_score <= et.engagement_score_cutoff
            THEN 'Disengagement'
        WHEN cs.tickets_90d >= tt.ticket_count_cutoff
            THEN 'Support Friction'
        WHEN cs.churn_probability_90d >= 0.7
            THEN 'Model Flagged (Critical) — no single metric threshold breached'
        ELSE NULL
    END AS trigger_reason,
    CASE
        WHEN cs.engagement_score <= et.engagement_score_cutoff
             AND cs.tickets_90d  >= tt.ticket_count_cutoff
             AND cs.arpu >= 750
            THEN 'Escalate to CSM for same-week call; offer service review + credit'
        WHEN cs.engagement_score <= et.engagement_score_cutoff
             AND cs.tickets_90d  >= tt.ticket_count_cutoff
            THEN 'Auto-enroll in win-back email sequence + priority support queue'
        WHEN cs.engagement_score <= et.engagement_score_cutoff
             AND cs.arpu >= 750
            THEN 'CSM outreach: re-engagement check-in + feature adoption walkthrough'
        WHEN cs.engagement_score <= et.engagement_score_cutoff
            THEN 'Trigger automated re-engagement email drip (product tips, unused features)'
        WHEN cs.tickets_90d >= tt.ticket_count_cutoff
             AND cs.arpu >= 750
            THEN 'Escalate open tickets to senior support; proactive resolution call'
        WHEN cs.tickets_90d >= tt.ticket_count_cutoff
            THEN 'Auto-flag ticket queue for priority handling + satisfaction follow-up'
        WHEN cs.churn_probability_90d >= 0.7
            THEN 'Manual review — model sees risk factors not captured by these two metrics'
        ELSE 'Monitor only, no action'
    END AS prescribed_action
FROM current_signals cs
CROSS JOIN engagement_threshold et
CROSS JOIN ticket_threshold tt
WHERE cs.engagement_score <= et.engagement_score_cutoff
   OR cs.tickets_90d  >= tt.ticket_count_cutoff
   OR cs.churn_probability_90d >= 0.7
ORDER BY cs.churn_probability_90d DESC NULLS LAST, cs.arpu DESC
LIMIT 200;

SELECT COUNT(*) AS active_customers,
       COUNT(fp.customer_id) AS have_prediction_row
FROM customer_churn_clean c
LEFT JOIN fact_churn_predictions fp ON fp.customer_id = c.customer_id
WHERE c.customer_status = 'Active';

SELECT c.risk_tier, COUNT(*) 
FROM customer_churn_clean c
JOIN fact_churn_predictions fp ON fp.customer_id = c.customer_id
WHERE c.customer_status = 'Active'
GROUP BY c.risk_tier
ORDER BY COUNT(*) DESC;



/* ===========================================================================================================================================
==============================================================================================================================================  */