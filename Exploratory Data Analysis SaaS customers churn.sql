/* =====================================================================
   SAAS CUSTOMER CHURN PREDICTION PROJECT
   Exploratory Data Analysis (EDA) — PostgreSQL Query Set
   Stage 8 of the project workflow (see Project Brief, Section 9)

   Organized into the 8 EDA focus areas defined in the project brief:
     1. Churn Rate & Trend
     2. Segment Profiling
     3. ARPU Distribution
     4. Tenure at Churn
     5. Engagement Trajectory
     6. Support Ticket Patterns
     7. Payment Failure Timing
     8. Survey Sentiment

   Source tables referenced: customer_churn_clean, dim_customers, dim_date,
   fact_usage_monthly, fact_engagement_monthly, fact_customer_monthly_snapshot,
   fact_payment_attempts, fact_support_tickets, dim_complaint_theme, fact_surveys
   ===================================================================== */

/* ============================================================================
   4.1 DESCRIPTIVE ANALYTICS — "What is happening?"
============================================================================ */
/* =========================================================================
   Standardization notes (read before running):

   1. `churn` is smallint (0/1) in customer_churn_clean — every query below
      uses `churn = 1` / `churn = 0`, never the string literal '1'. Where a
      boolean read is more natural, `churn_flag` (TRUE/FALSE) is used instead.
   2. `customer_churn_clean` is your single denormalized analytical table —
      it already carries customer_segment, country, tenure_months, arpu,
      total_revenue, etc. Several original queries joined out to
      `dim_customers` for attributes that already exist on
      customer_churn_clean; those joins have been removed where redundant.
      Joins to genuinely separate fact tables (engagement, tickets,
      payments, surveys, complaint themes) are kept, since that data isn't
      denormalized into customer_churn_clean.
   3. `arpu` (not `total_revenue`) is used wherever the business question is
      specifically about ARPU — total_revenue is a cumulative/lifetime
      figure and answers a different question (see Section 3 note).
   4. `is_outlier` (IQR-based, built on `arpu`) is applied consistently in
      any query computing a mean/variance on `arpu`, matching the
      methodology used in the Welch's t-test work already done.
   5. `tenure_band` / `tenure_at_churn` (both already built) replace the
      inline CASE-statement tenure bucketing that was being repeated in
      Section 4 — one definition, used everywhere, instead of two
      re-derivations that could drift apart.
   6. A bug fix: original query 7a divided by `NULLIF(COUNT(*), 2)` — that
      2 should be 0 (NULLIF is a divide-by-zero guard, not a threshold).
      Fixed below.
   7. Queries against fact_customers-style tables (dim_customers,
      fact_customer_monthly_snapshot, fact_engagement_monthly,
      fact_support_tickets, dim_complaint_theme, fact_payment_attempts,
      fact_surveys) assume the column names used originally
      (churn_date, sign_up_date, usage_month, etc.). I haven't seen those
      tables' schemas directly — if any column name below throws an
      "does not exist" error, run:
          SELECT column_name, data_type FROM information_schema.columns
          WHERE table_name = '<table_name>';
      and I'll adjust.
   ========================================================================= */

/* =========================================================================
   1. CHURN RATE & TREND
   Business question: What is the overall churn rate, and how has it
   trended over time (monthly/quarterly)?
   ========================================================================= */

-- 1a. Overall churn rate (headline metric)
SELECT
    COUNT(*) FILTER (WHERE churn = 1)                              AS churned_customers,
    COUNT(*)                                                        AS total_customers,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                                                AS churn_rate_pct
FROM customer_churn_clean;

-- 1b. Monthly churn trend
SELECT
    DATE_TRUNC('month', churn_date)::date AS churn_month,
    COUNT(*)                              AS customers_churned
FROM dim_customers
WHERE churn = 1
GROUP BY 1
ORDER BY 1;

-- 1c. Quarterly view of the same trend, with a rolling 3-month churn count
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', churn_date)::date AS churn_month,
        COUNT(*)                              AS customers_churned
    FROM dim_customers
    WHERE churn = 1
    GROUP BY 1
)
SELECT
    churn_month,
    customers_churned,
    SUM(customers_churned) OVER (
        ORDER BY churn_month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS rolling_3mo_churned
FROM monthly
ORDER BY churn_month;

-- 1d. Quarter-over-quarter churn RATE (needs an active-base denominator per
--     quarter, hence the separate monthly snapshot fact table rather than
--     the static customer_churn_clean table)
SELECT
    DATE_TRUNC('quarter', s.snapshot_month)::date                              AS quarter,
    COUNT(DISTINCT s.customer_id) FILTER (WHERE s.customer_status = 'Churned') AS churned,
    COUNT(DISTINCT s.customer_id)                                              AS base,
    ROUND(
        COUNT(DISTINCT s.customer_id) FILTER (WHERE s.customer_status = 'Churned')::numeric
        / NULLIF(COUNT(DISTINCT s.customer_id), 0) * 100, 2
    )                                                                           AS churn_rate_pct
FROM fact_customer_monthly_snapshot s
GROUP BY 1
ORDER BY 1;


/* =========================================================================
   2. SEGMENT PROFILING
   Business question: Which segments over- or under-index on churn?
   ========================================================================= */

-- 2a. Churn rate by customer_segment
--     (dim_customers join removed — customer_segment already lives on
--     customer_churn_clean, so the join added nothing but risk of
--     duplicate rows if dim_customers isn't 1:1 on customer_id)
SELECT
    customer_segment,
    COUNT(*)                              AS customers,
    COUNT(*) FILTER (WHERE churn = 1)     AS churned,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                      AS churn_rate_pct
FROM customer_churn_clean
GROUP BY customer_segment
ORDER BY churn_rate_pct DESC;

-- 2b. Churn rate by country
SELECT
    country,
    COUNT(*)                              AS customers,
    COUNT(*) FILTER (WHERE churn = 1)     AS churned,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                      AS churn_rate_pct
FROM customer_churn_clean
GROUP BY country
ORDER BY churn_rate_pct DESC;

-- 2c. Revenue concentration by segment
--     (total_revenue is correct here — this question is about share of
--     total company revenue, not per-user ARPU, so total_revenue is the
--     right column, not arpu)
SELECT
    customer_segment,
    COUNT(*)                              AS customers,
    ROUND(SUM(total_revenue)::numeric, 2) AS segment_revenue,
    ROUND(
        SUM(total_revenue)
        / NULLIF(SUM(SUM(total_revenue)) OVER (), 0) * 100,
        2
    )                                      AS revenue_share_pct
FROM customer_churn_clean
WHERE total_revenue IS NOT NULL
GROUP BY customer_segment
ORDER BY revenue_share_pct DESC;


/* =========================================================================
   3. ARPU DISTRIBUTION
   Business question: Does the ARPU distribution (not just the mean)
   support the price-parity finding?
   ---------------------------------------------------------------------
   Switched from total_revenue to arpu throughout this section — arpu is
   the per-user revenue metric this question is actually about;
   total_revenue is a cumulative figure and answers a different question
   (see Section 2c). is_outlier filter applied to stay consistent with the
   t-test methodology already validated earlier in the project.
   ========================================================================= */
   
-- 3a. Compare ARPU between churned and active customers
SELECT
    churn,
    COUNT(*) AS customer_count,
    ROUND(AVG(monthly_fee), 2) AS arpu
FROM customer_churn_clean
GROUP BY churn
ORDER BY churn;

-- Churn rate by contract_type alone
SELECT
    contract_type,
    COUNT(*) AS total_customers,
    ROUND(COUNT(*) FILTER (WHERE churn = 1)::numeric / NULLIF(COUNT(*), 0) * 100, 2) AS churn_rate_pct
FROM customer_churn_clean
GROUP BY contract_type
ORDER BY churn_rate_pct DESC;

-- 3b. Summary statistics by segment
SELECT
    customer_segment,
    COUNT(*)                                                            AS customers,
    ROUND(AVG(arpu)::numeric, 2)                                        AS mean_arpu,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS p25_arpu,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS median_arpu,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS p75_arpu,
    ROUND(MIN(arpu)::numeric, 2)                                        AS min_arpu,
    ROUND(MAX(arpu)::numeric, 2)                                        AS max_arpu,
    ROUND(STDDEV(arpu)::numeric, 2)                                     AS stddev_arpu
FROM customer_churn_clean
WHERE arpu IS NOT NULL
  AND is_outlier = FALSE
GROUP BY customer_segment
ORDER BY mean_arpu DESC;


-- Distribution summary statistics
SELECT
    CASE WHEN churn_flag THEN 'Churned' ELSE 'Retained' END        AS customer_status,
    COUNT(*)                                                       AS n,
    ROUND(AVG(arpu)::numeric, 2)                                   AS mean_arpu,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arpu)::numeric, 2) AS median_arpu,
    ROUND(STDDEV(arpu)::numeric, 2)                                AS stddev_arpu,
    ROUND(MIN(arpu)::numeric, 2)                                   AS min_arpu,
    ROUND(MAX(arpu)::numeric, 2)                                   AS max_arpu
FROM customer_churn_clean
WHERE is_outlier = FALSE
GROUP BY churn_flag;
 
-- Histogram buckets for chart output
SELECT
    WIDTH_BUCKET(arpu, 0, 200, 20)                            AS arpu_bucket,
    CASE WHEN churn_flag THEN 'Churned' ELSE 'Retained' END   AS customer_status,
    COUNT(*)                                                  AS customers
FROM customer_churn_clean
WHERE is_outlier = FALSE
GROUP BY 1, 2
ORDER BY 1, 2;

-- 3c. ARPU decile assignment, churned vs retained (feeds a histogram / box-plot)
SELECT
    customer_id,
    customer_status,
    ROUND(arpu::numeric, 2) AS arpu,
    NTILE(10) OVER (ORDER BY arpu) AS arpu_decile
FROM customer_churn_clean
WHERE arpu IS NOT NULL
  AND customer_status IS NOT NULL
  AND is_outlier = FALSE
ORDER BY arpu;

-- 3d. ARPU summary, churned vs retained (the core price-parity check)
SELECT
    customer_status,
    COUNT(*)                                                            AS customers,
    ROUND(AVG(arpu)::numeric, 2)                                        AS mean_arpu,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS q1_arpu,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS median_arpu,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS q3_arpu,
    ROUND(MIN(arpu)::numeric, 2)                                        AS min_arpu,
    ROUND(MAX(arpu)::numeric, 2)                                        AS max_arpu
FROM customer_churn_clean
WHERE arpu IS NOT NULL
  AND customer_status IS NOT NULL
  AND is_outlier = FALSE
GROUP BY customer_status
ORDER BY customer_status;

-- 3e. ARPU by segment, churned vs retained (does parity hold within every segment,
--     or only in the blended average?)
SELECT
    customer_segment,
    customer_status,
    COUNT(*)                                                            AS customers,
    ROUND(AVG(arpu)::numeric, 2)                                        AS avg_arpu,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS median_arpu,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS p25_arpu,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY arpu)::numeric,2) AS p75_arpu
FROM customer_churn_clean
WHERE arpu IS NOT NULL
  AND customer_status IS NOT NULL
  AND is_outlier = FALSE
GROUP BY customer_segment, customer_status
ORDER BY customer_segment, customer_status;

select *
from customer_churn_clean;


/* =========================================================================
   4. TENURE AT CHURN
   Business question: How concentrated is churn in the early-tenure
   window, and where exactly does it spike?
   ---------------------------------------------------------------------
   Uses the tenure_band column already built on customer_churn_clean
   (0-2 / 3-5 / 6-11 / 12-23 / 24+ months) instead of re-deriving the
   bucketing logic inline in every query — one definition, used
   everywhere, so results can't silently drift between queries.
   ========================================================================= */

-- 4a. Tenure-at-churn distribution by band
SELECT
    tenure_band,
    COUNT(*)                                                   AS churned_customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)         AS pct_of_all_churn,
    ROUND(AVG(tenure_at_churn)::numeric, 1)                    AS avg_tenure_months_in_band
FROM customer_churn_clean
WHERE churn = 1
GROUP BY tenure_band
ORDER BY MIN(tenure_at_churn);


-- 4b. Churn RATE by tenure band, against the full base (not just churned rows) —
--     tells you whether early-tenure customers churn at a higher rate, not just
--     a higher share of total churn volume
SELECT
    tenure_band,
    COUNT(*)                                            AS total_customers,
    COUNT(*) FILTER (WHERE churn = 1)                   AS churned_customers,
    COUNT(*) FILTER (WHERE churn = 0)                   AS currently_active,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 1)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                                    AS churn_rate_pct,
    ROUND(
        COUNT(*) FILTER (WHERE churn = 0)::numeric
        / NULLIF(SUM(COUNT(*) FILTER (WHERE churn = 0)) OVER (), 0) * 100, 2
    )                                                    AS active_base_share_pct
FROM customer_churn_clean
WHERE tenure_band IS NOT NULL
GROUP BY tenure_band
ORDER BY MIN(tenure_months);

-- 4c. Exact 6-month (180-day) concentration check — validates a headline
--     "X% of churn happens within the first 6 months" figure
SELECT
    ROUND(
        COUNT(*) FILTER (WHERE tenure_months <= 6)::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    ) AS pct_churn_within_6_months
FROM customer_churn_clean
WHERE churn = 1;

select *
from customer_churn_clean;


-- 4d. Current active base by tenure band, for forward-looking risk sizing
--     (how many *currently active* customers sit inside the highest-risk
--     early-tenure window right now?)
SELECT
    tenure_band,
    COUNT(*) AS active_customers
FROM customer_churn_clean
WHERE churn = 0
GROUP BY tenure_band
ORDER BY
    CASE tenure_band
        WHEN '0-2 months'   THEN 1
        WHEN '3-5 months'   THEN 2
        WHEN '6-11 months'  THEN 3
        WHEN '12-23 months' THEN 4
        WHEN '24+ months'   THEN 5
    END;


/* =========================================================================
   5. ENGAGEMENT TRAJECTORY
   Business question: Does engagement visibly decline before churn, and
   how many months in advance?
   ========================================================================= */
   
-- 5a. Average engagement score by "months before churn", churned customers only
WITH churned_engagement AS (
    SELECT
        e.customer_id,
        (DATE_PART('year', AGE(dc.churn_date, e.usage_month)) * 12
         + DATE_PART('month', AGE(dc.churn_date, e.usage_month)))::int AS months_before_churn,
        e.engagement_score
    FROM fact_engagement_monthly e
    JOIN dim_customers dc ON dc.customer_id = e.customer_id
    WHERE dc.churn = 1
)
SELECT
    months_before_churn,
    ROUND(AVG(engagement_score), 2) AS avg_engagement_score,
    COUNT(*)                        AS observations
FROM churned_engagement
WHERE months_before_churn BETWEEN 0 AND 6
GROUP BY months_before_churn
ORDER BY months_before_churn;

-- 5b. Engagement trend slope per churned customer over their final 3 months on record
WITH last_3mo AS (
    SELECT
        e.customer_id,
        e.usage_month,
        e.engagement_score,
        ROW_NUMBER() OVER (PARTITION BY e.customer_id ORDER BY e.usage_month DESC) AS rn
    FROM fact_engagement_monthly e
    JOIN customer_churn_clean cc ON cc.customer_id = e.customer_id
    WHERE cc.churn = 1
)
SELECT
    customer_id,
    REGR_SLOPE(engagement_score, EXTRACT(EPOCH FROM usage_month)) AS engagement_slope
FROM last_3mo
WHERE rn <= 3
GROUP BY customer_id
HAVING COUNT(*) = 3;

-- 5c. Retained-customer baseline engagement score, for comparison against 5a
SELECT
    ROUND(AVG(e.engagement_score), 2) AS avg_engagement_score_retained
FROM fact_engagement_monthly e
JOIN customer_churn_clean cc ON cc.customer_id = e.customer_id
WHERE cc.churn = 0;

-- 5d. Customers with a >=15-point engagement drop between their two most
--     recent months on record (rewritten with LAG for clarity — the
--     original FIRST_VALUE/LAST_VALUE version relied on a frame that's
--     easy to misread; LAG over ascending usage_month is unambiguous)
WITH ordered AS (
    SELECT
        customer_id,
        usage_month,
        engagement_score,
        LAG(engagement_score) OVER (PARTITION BY customer_id ORDER BY usage_month) AS prior_score,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY usage_month DESC)      AS recency_rank
    FROM fact_engagement_monthly
)
SELECT
    customer_id,
    prior_score,
    engagement_score AS latest_score,
    (prior_score - engagement_score) AS score_drop
FROM ordered
WHERE recency_rank = 1
  AND prior_score IS NOT NULL
  AND (prior_score - engagement_score) >= 15   -- threshold to be validated in EDA
ORDER BY score_drop DESC;


/* =========================================================================
   6. SUPPORT TICKET PATTERNS
   Business question: Which complaint themes are most associated with
   churn?
   ========================================================================= */

-- 6a. Churn rate among customers who logged at least one ticket of each theme
SELECT
    dt.theme_name,
    COUNT(DISTINCT t.customer_id)                                    AS customers_with_theme,
    COUNT(DISTINCT t.customer_id) FILTER (WHERE cc.churn = 1)        AS churned_customers,
    ROUND(
        COUNT(DISTINCT t.customer_id) FILTER (WHERE cc.churn = 1)::numeric
        / NULLIF(COUNT(DISTINCT t.customer_id), 0) * 100, 2
    )                                                                 AS churn_rate_pct
FROM fact_support_tickets t
JOIN dim_complaint_theme dt   ON dt.theme_id = t.theme_id
JOIN customer_churn_clean cc  ON cc.customer_id = t.customer_id
GROUP BY dt.theme_name
ORDER BY churn_rate_pct DESC;

-- 6b. Average ticket volume per customer, churned vs retained
SELECT
    cc.churn,
    ROUND(AVG(tc.ticket_count), 2) AS avg_tickets_per_customer
FROM (
    SELECT customer_id, COUNT(*) AS ticket_count
    FROM fact_support_tickets
    GROUP BY customer_id
) tc
JOIN customer_churn_clean cc ON cc.customer_id = tc.customer_id
GROUP BY cc.churn;

-- 6c. Complaint theme mix as % of tickets, churned vs retained (composition, not volume)
SELECT
    cc.churn,
    dt.theme_name,
    COUNT(*)                                                              AS ticket_count,
    ROUND(
        COUNT(*)::numeric / SUM(COUNT(*)) OVER (PARTITION BY cc.churn) * 100, 2
    )                                                                      AS pct_of_group_tickets
FROM fact_support_tickets t
JOIN dim_complaint_theme dt  ON dt.theme_id = t.theme_id
JOIN customer_churn_clean cc ON cc.customer_id = t.customer_id
GROUP BY cc.churn, dt.theme_name
ORDER BY cc.churn, ticket_count DESC;

-- 6d. Average resolution time by theme (unresolved friction as a churn driver)
SELECT
    dt.theme_name,
    ROUND(AVG(t.resolution_time_hours), 1) AS avg_resolution_time_hours,
    COUNT(*)                               AS ticket_count
FROM fact_support_tickets t
JOIN dim_complaint_theme dt ON dt.theme_id = t.theme_id
GROUP BY dt.theme_name
ORDER BY avg_resolution_time_hours DESC;

-- 6e. Ticket volume and complaint mix by country
SELECT
    c.country,
    dt.theme_name,
    COUNT(*) AS ticket_count
FROM fact_support_tickets t
JOIN dim_customers c        ON c.customer_id = t.customer_id
JOIN dim_complaint_theme dt ON dt.theme_id = t.theme_id
GROUP BY c.country, dt.theme_name
ORDER BY c.country, ticket_count DESC;


/* =========================================================================
   7. PAYMENT FAILURE TIMING
   Business question: Do failures cluster right before churn (symptom) or
   much earlier (cause)?
   ---------------------------------------------------------------------
   Fixed a bug from the original 7a: NULLIF(COUNT(*), 2) is a
   divide-by-zero guard, not a threshold — the 2 was a typo for 0.
   ========================================================================= */

-- 7a. Payment failure rate, churned vs retained
SELECT
    cc.churn,
    ROUND(
        COUNT(*) FILTER (WHERE p.status = 'Failed')::numeric
        / NULLIF(COUNT(*), 0) * 100, 2
    ) AS failure_rate_pct
FROM fact_payment_attempts p
JOIN customer_churn_clean cc ON cc.customer_id = p.customer_id
GROUP BY cc.churn;

-- 7b. Days between each churned customer's last payment failure and their churn date
WITH last_failure AS (
    SELECT customer_id, MAX(payment_date) AS last_failure_date
    FROM fact_payment_attempts
    WHERE status = 'Failed'
    GROUP BY customer_id
)
SELECT
    dm.customer_id,
    (dm.churn_date - lf.last_failure_date) AS days_between_failure_and_churn
FROM last_failure lf
JOIN dim_customers dm ON dm.customer_id = lf.customer_id
WHERE dm.churn = 1
ORDER BY days_between_failure_and_churn
LIMIT 50;

-- 7c. Bucketed distribution of that gap — clustered near 0 implies failures
--     are a symptom of churn; spread out implies an earlier, independent cause
WITH last_failure AS (
    SELECT customer_id, MAX(payment_date) AS last_failure_date
    FROM fact_payment_attempts
    WHERE status = 'Failed'
    GROUP BY customer_id
),
gap AS (
    SELECT (dm.churn_date - lf.last_failure_date) AS days_gap
    FROM last_failure lf
    JOIN dim_customers dm ON dm.customer_id = lf.customer_id
    WHERE dm.churn = 1
)
SELECT
    CASE
        WHEN days_gap <= 14 THEN '0-14 days before churn'
        WHEN days_gap <= 30 THEN '15-30 days before churn'
        WHEN days_gap <= 60 THEN '31-60 days before churn'
        ELSE '60+ days before churn'
    END AS gap_bucket,
    COUNT(*) AS customers
FROM gap
GROUP BY 1
ORDER BY MIN(days_gap);

-- 7d. Sequencing check: does an engagement drop precede a payment failure,
--     or does the failure come first?
SELECT
    p.customer_id,
    p.payment_date  AS failure_date,
    e.usage_month   AS engagement_month,
    e.engagement_score
FROM fact_payment_attempts p
JOIN fact_engagement_monthly e ON e.customer_id = p.customer_id
WHERE p.status = 'Failed'
  AND e.usage_month = DATE_TRUNC('month', p.payment_date - INTERVAL '1 month')
ORDER BY p.customer_id, p.payment_date
LIMIT 50;


/* =========================================================================
   8. SURVEY SENTIMENT
   Business question: Does stated satisfaction diverge from behavioral
   engagement signals?
   ========================================================================= */

-- 8a. CSAT / NPS summary, churned vs retained
SELECT
    dm.churn,
    ROUND(AVG(s.csat_score), 2) AS avg_csat,
    ROUND(AVG(s.nps_score), 2)  AS avg_nps,
    COUNT(*)                    AS survey_responses
FROM fact_surveys s
JOIN dim_customers dm ON dm.customer_id = s.customer_id
GROUP BY dm.churn;

-- 8b. NPS category split (Promoter / Passive / Detractor) by churn outcome
SELECT
    cc.churn,
    CASE
        WHEN s.nps_score >= 9 THEN 'Promoter'
        WHEN s.nps_score >= 7 THEN 'Passive'
        ELSE 'Detractor'
    END AS nps_category,
    COUNT(*) AS responses
FROM fact_surveys s
JOIN customer_churn_clean cc ON cc.customer_id = s.customer_id
GROUP BY cc.churn, 2
ORDER BY cc.churn, 2;

-- 8c. Survey sentiment vs. behavioral engagement in the same month
--     (raw pairs — feeds a correlation calc downstream)
SELECT
    s.customer_id,
    s.survey_date,
    s.csat_score,
    e.engagement_score
FROM fact_surveys s
JOIN fact_engagement_monthly e
    ON e.customer_id = s.customer_id
   AND e.usage_month = DATE_TRUNC('month', s.survey_date)
ORDER BY s.customer_id, s.survey_date;

-- 8d. "Silent churner" pattern: high CSAT before churning anyway
SELECT
    s.customer_id,
    s.csat_score,
    dm.churn_date
FROM fact_surveys s
JOIN dim_customers dm ON dm.customer_id = s.customer_id
WHERE dm.churn = 1
  AND s.csat_score >= 3
  AND s.survey_date < dm.churn_date
ORDER BY s.csat_score DESC;

/* =========================================================================
   END OF STAGE 9 QUERY SET
   ========================================================================= */


