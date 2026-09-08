5-- ============================================================
-- 01_create_table.sql
-- Creates the raw landing table for customer_churn_business_dataset.csv
-- ============================================================

-- Important: Always highlight the intended SQL query before clicking 'Run' to ensure that only the selected query is executed.


DROP TABLE IF EXISTS customer_churn_raw;

CREATE TABLE customer_churn_raw (
    customer_id             TEXT PRIMARY KEY,
    gender                  TEXT,
    age                     INTEGER,
    country                 TEXT,
    city                    TEXT,
    customer_segment        TEXT,
    tenure_months            INTEGER,
    signup_channel          TEXT,
    contract_type           TEXT,
    monthly_logins          INTEGER,
    weekly_active_days      INTEGER,
    avg_session_time        NUMERIC(10,4),
    features_used           INTEGER,
    usage_growth_rate       NUMERIC(10,4),
    last_login_days_ago     INTEGER,
    monthly_fee             INTEGER,
    total_revenue           INTEGER,
    payment_method          TEXT,
    payment_failures        INTEGER,
    discount_applied        TEXT,      -- 'Yes'/'No' in source; cast to boolean in cleaning step
    price_increase_last_3m  TEXT,      -- 'Yes'/'No' in source; cast to boolean in cleaning step
    support_tickets         INTEGER,
    avg_resolution_time     NUMERIC(10,4),
    complaint_type          TEXT,      -- has ~20% NULLs in source (no complaint filed)
    csat_score               NUMERIC(3,1),
    escalations              INTEGER,
    email_open_rate          NUMERIC(5,4),
    marketing_click_rate     NUMERIC(5,4),
    nps_score                INTEGER,
    survey_response          TEXT,
    referral_count            INTEGER,
    churn                    SMALLINT   -- 0 or 1
);


SELECT COUNT(*)
FROM customer_churn_raw;

SELECT * 
FROM customer_churn_raw LIMIT 5000;



-- ===============================================================
-- Design rationale: star schema, one fact table per event type
-- Step 1 — dim_customers
CREATE TABLE dim_customers (
    customer_id        TEXT PRIMARY KEY,
    gender              TEXT,
    age                 INTEGER,
    country              TEXT,
    city                TEXT,
    customer_segment     TEXT,
    signup_channel       TEXT,
    contract_type        TEXT,
    payment_method        TEXT,
    signup_date          DATE,
    tenure_months        INTEGER,
    monthly_fee           NUMERIC(10,2),
    total_revenue          NUMERIC(12,2),
    discount_applied       BOOLEAN,
    price_increase_last_3m BOOLEAN,
    churn                 SMALLINT,          -- 0/1 flag, kept from source
    churn_date            DATE               -- NULL if still active
);



SELECT COUNT(*) FROM dim_customers;

SELECT DISTINCT discount_applied FROM customer_churn_clean;

SELECT DISTINCT price_increase_last_3m FROM customer_churn_clean;
SELECT customer_id, discount_applied, price_increase_last_3m, churn, churn_date
FROM dim_customers
LIMIT 5;

SELECT DISTINCT discount_applied FROM customer_churn_clean;
SELECT DISTINCT price_increase_last_3m FROM customer_churn_clean;

INSERT INTO dim_customers
SELECT
    customer_id, gender, age, country, city, customer_segment, signup_channel,
    contract_type, payment_method, signup_date, tenure_months, monthly_fee,
    total_revenue,
    CASE WHEN discount_applied = 'Yes' THEN TRUE ELSE FALSE END AS discount_applied,
    CASE WHEN price_increase_last_3m = 'Yes' THEN TRUE ELSE FALSE END AS price_increase_last_3m,
    churn,
    CASE WHEN churn = 1
         THEN (signup_date + (tenure_months || ' months')::interval)::date
         ELSE NULL
    END AS churn_date
FROM customer_churn_clean;

SELECT COUNT(*) FROM dim_customers;
-- should be 10000

SELECT customer_id, discount_applied, price_increase_last_3m, churn, churn_date
FROM dim_customers
LIMIT 5;
SELECT COUNT(*) FROM dim_customers;
-- discount_applied / price_increase_last_3m should show t/f (true/false), not text

-- ========================================================================================================
-- Step 2 — fact_support_tickets (root cause + behavioral analysis)

CREATE TABLE fact_support_tickets (
    ticket_id                SERIAL PRIMARY KEY,
    customer_id                TEXT REFERENCES dim_customers(customer_id),
    ticket_date                  DATE,
    complaint_type                 TEXT,
    resolution_time_hours            NUMERIC(6,2),
    escalated                          BOOLEAN
);

INSERT INTO fact_support_tickets (customer_id, ticket_date, complaint_type, resolution_time_hours, escalated)
SELECT
    c.customer_id,
    (c.signup_date + (FLOOR(RANDOM() * GREATEST(c.tenure_months,1)) || ' months')::interval
                    + (FLOOR(RANDOM() * 28) || ' days')::interval)::date AS ticket_date,
    src.complaint_type,
    GREATEST(1, ROUND((src.avg_resolution_time + (RANDOM() - 0.5) * 4)::numeric, 2)) AS resolution_time_hours,
    CASE WHEN RANDOM() < (src.escalations::numeric / GREATEST(src.support_tickets,1)) THEN TRUE ELSE FALSE END AS escalated
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
CROSS JOIN LATERAL generate_series(1, src.support_tickets) AS ticket_n
WHERE src.support_tickets > 0;


SELECT c.customer_id, src.support_tickets AS expected, COUNT(t.ticket_id) AS actual
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
LEFT JOIN fact_support_tickets t USING (customer_id)
GROUP BY c.customer_id, src.support_tickets
HAVING COUNT(t.ticket_id) != src.support_tickets;

-- ==========================================================================================================
-- Step 3 — fact_payment_attempts (billing root-cause, funnel input)
CREATE TABLE fact_payment_attempts (
    payment_id          SERIAL PRIMARY KEY,
    customer_id           TEXT REFERENCES dim_customers(customer_id),
    payment_date            DATE,
    amount                    NUMERIC(10,2),
    status                     TEXT
);

INSERT INTO fact_payment_attempts (customer_id, payment_date, amount, status)
SELECT
    c.customer_id,
    (c.signup_date + (m.month_n || ' months')::interval)::date AS payment_date,
    c.monthly_fee,
    CASE WHEN m.month_n <= src.payment_failures THEN 'Failed' ELSE 'Success' END AS status
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
CROSS JOIN LATERAL generate_series(1, GREATEST(c.tenure_months,1)) AS m(month_n);


SELECT c.customer_id, src.payment_failures AS expected, 
       COUNT(*) FILTER (WHERE fp.status = 'Failed') AS actual
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
LEFT JOIN fact_payment_attempts fp USING (customer_id)
GROUP BY c.customer_id, src.payment_failures
HAVING COUNT(*) FILTER (WHERE fp.status = 'Failed') != src.payment_failures;

TRUNCATE TABLE fact_payment_attempts;

INSERT INTO fact_payment_attempts (customer_id, payment_date, amount, status)
SELECT
    c.customer_id,
    (c.signup_date + (m.month_n || ' months')::interval)::date AS payment_date,
    c.monthly_fee,
    CASE WHEN m.month_n <= src.payment_failures THEN 'Failed' ELSE 'Success' END AS status
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
CROSS JOIN LATERAL generate_series(1, GREATEST(c.tenure_months, src.payment_failures, 1)) AS m(month_n);

SELECT c.customer_id, src.payment_failures AS expected, 
       COUNT(*) FILTER (WHERE fp.status = 'Failed') AS actual
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id)
LEFT JOIN fact_payment_attempts fp USING (customer_id)
GROUP BY c.customer_id, src.payment_failures
HAVING COUNT(*) FILTER (WHERE fp.status = 'Failed') != src.payment_failures;

-- ===============================================================================================
-- Step 4 — fact_surveys (satisfaction root-cause)
CREATE TABLE fact_surveys (
    survey_id           SERIAL PRIMARY KEY,
    customer_id           TEXT REFERENCES dim_customers(customer_id),
    survey_date             DATE,
    csat_score               NUMERIC(3,1),
    nps_score                 INTEGER,
    survey_response             TEXT
);

INSERT INTO fact_surveys (customer_id, survey_date, csat_score, nps_score, survey_response)
SELECT
    c.customer_id,
    (c.signup_date + ((c.tenure_months / 2) || ' months')::interval)::date AS survey_date,
    src.csat_score,
    src.nps_score,
    src.survey_response
FROM customer_churn_clean src
JOIN dim_customers c USING (customer_id);

SELECT COUNT(*), COUNT(customer_id) FROM fact_surveys;

-- ====================================================================================================
-- Step 5 — dim_date (calendar dimension for cohort/funnel joins)
CREATE TABLE dim_date (
    date_key      DATE PRIMARY KEY,
    year            INTEGER,
    month             INTEGER,
    month_name          TEXT,
    quarter               INTEGER,
    day_of_week             INTEGER,
    is_weekend                BOOLEAN
);

INSERT INTO dim_date
SELECT
    d::date,
    EXTRACT(YEAR FROM d)::int,
    EXTRACT(MONTH FROM d)::int,
    TRIM(TO_CHAR(d, 'Month')),
    EXTRACT(QUARTER FROM d)::int,
    EXTRACT(DOW FROM d)::int,
    EXTRACT(DOW FROM d) IN (0,6)
FROM generate_series('2021-01-01'::date, '2026-12-31'::date, '1 day') AS d;


SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('fact_surveys', 'fact_support_tickets', 'customer_churn_clean', 'dim_customers')
ORDER BY table_name, ordinal_position;


SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('fact_payment_attempts', 'dim_date')
ORDER BY table_name, ordinal_position;


CREATE TABLE fact_usage_monthly (
    usage_id            SERIAL PRIMARY KEY,
    customer_id          TEXT NOT NULL REFERENCES dim_customers(customer_id),
    usage_month          DATE NOT NULL,          -- always the 1st of the month, e.g. '2025-03-01'
    monthly_logins       INTEGER,
    weekly_active_days   INTEGER,
    avg_session_time     NUMERIC,
    features_used        INTEGER,
    usage_growth_rate    NUMERIC,                -- MoM % change vs. prior month
    UNIQUE (customer_id, usage_month)
);

CREATE INDEX idx_usage_monthly_customer ON fact_usage_monthly (customer_id);
CREATE INDEX idx_usage_monthly_month ON fact_usage_monthly (usage_month);


INSERT INTO fact_usage_monthly (customer_id, usage_month, monthly_logins, weekly_active_days, avg_session_time, features_used)
SELECT
    c.customer_id,
    gs.usage_month::date,

    GREATEST(
        1,
        ROUND(
            c.monthly_logins *
            CASE
                WHEN c.churn = 1 THEN
                    GREATEST(0.2, 1 - (0.12 * (12 - LEAST(12, EXTRACT(MONTH FROM AGE(dc.churn_date, gs.usage_month))))))
                ELSE
                    (0.85 + RANDOM() * 0.3)
            END
        )
    )::integer AS monthly_logins,

    GREATEST(1, ROUND(c.weekly_active_days * (0.8 + RANDOM() * 0.4)))::integer AS weekly_active_days,
    GREATEST(1, ROUND((c.avg_session_time * (0.8 + RANDOM() * 0.4))::numeric, 2)) AS avg_session_time,
    GREATEST(1, ROUND(c.features_used * (0.85 + RANDOM() * 0.3)))::integer AS features_used

FROM customer_churn_clean c
JOIN dim_customers dc ON dc.customer_id = c.customer_id
JOIN LATERAL (
    SELECT generate_series(
        DATE_TRUNC('month', c.signup_date)::date,
        DATE_TRUNC('month', COALESCE(dc.churn_date, CURRENT_DATE))::date,
        INTERVAL '1 month'
    ) AS usage_month
) gs ON TRUE
WHERE c.signup_date IS NOT NULL;


-- 1. Row count and coverage check
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS unique_customers,
    MIN(usage_month) AS earliest_month,
    MAX(usage_month) AS latest_month
FROM fact_usage_monthly;

-- 2. Spot-check: does login count decline in the months before churn for a churned customer?
SELECT
    f.customer_id,
    f.usage_month,
    f.monthly_logins,
    dc.churn_date
FROM fact_usage_monthly f
JOIN dim_customers dc ON dc.customer_id = f.customer_id
WHERE dc.churn = 1
ORDER BY f.customer_id, f.usage_month
LIMIT 30;


UPDATE fact_usage_monthly f
SET usage_growth_rate = ROUND(
    ((f.monthly_logins - prev.monthly_logins)::numeric / NULLIF(prev.monthly_logins, 0)) * 100, 2
)
FROM fact_usage_monthly prev
WHERE f.customer_id = prev.customer_id
  AND prev.usage_month = f.usage_month - INTERVAL '1 month';


-- Data Validation


-- Row count check: should roughly equal sum of each customer's active months
SELECT COUNT(*) FROM fact_usage_monthly;

-- Spot check: does login trend actually decline before churn for churned customers?
SELECT customer_id, usage_month, monthly_logins, usage_growth_rate
FROM fact_usage_monthly
WHERE customer_id IN (SELECT customer_id FROM customer_churn_clean WHERE churn = 1 LIMIT 3)
ORDER BY customer_id, usage_month;


SELECT
    LEAST(12, EXTRACT(MONTH FROM AGE(dc.churn_date, f.usage_month))::int) AS months_before_churn,
    ROUND(AVG(f.monthly_logins), 2) AS avg_logins,
    COUNT(*) AS data_points
FROM fact_usage_monthly f
JOIN dim_customers dc ON dc.customer_id = f.customer_id
WHERE dc.churn = 1
  AND f.usage_month <= dc.churn_date
GROUP BY LEAST(12, EXTRACT(MONTH FROM AGE(dc.churn_date, f.usage_month))::int)
ORDER BY months_before_churn DESC;

SELECT DISTINCT status, COUNT(*) AS row_count
FROM fact_payment_attempts
GROUP BY status
ORDER BY row_count DESC;


-- Add customer_status column to dim_customers if it doesn't already exist
ALTER TABLE dim_customers
ADD COLUMN IF NOT EXISTS customer_status VARCHAR(20);

UPDATE dim_customers dc
SET customer_status = ccc.customer_status
FROM customer_churn_clean ccc
WHERE dc.customer_id = ccc.customer_id;

-- Check row counts match and no nulls slipped through
SELECT
    COUNT(*) AS total_rows,
    COUNT(customer_status) AS populated_rows,
    COUNT(*) - COUNT(customer_status) AS null_rows
FROM dim_customers;


-- Confirm the distribution looks right (should roughly match your earlier churn rate)
SELECT
    customer_status,
    COUNT(*) AS customer_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_base
FROM dim_customers
GROUP BY customer_status
ORDER BY customer_count DESC;

ALTER TABLE fact_usage_monthly
ADD COLUMN last_login_days_ago INTEGER;

UPDATE fact_usage_monthly fum
SET last_login_days_ago = c.last_login_days_ago
FROM customer_churn_clean c
WHERE fum.customer_id = c.customer_id;

SELECT
    customer_id,
    last_login_days_ago
FROM fact_usage_monthly
LIMIT 10;

UPDATE fact_usage_monthly fum
SET last_login_days_ago = c.last_login_days_ago
FROM customer_churn_clean c
WHERE fum.customer_id = c.customer_id;


ALTER TABLE customer_churn_clean
ADD COLUMN engagement_score NUMERIC(5,2);

UPDATE customer_churn_clean
SET engagement_score =
ROUND(
(
    -- Login Frequency (Maximum = 30)
    LEAST(login_frequency, 30) / 30.0 * 35

    +

    -- Feature Usage (Maximum = 20)
    LEAST(feature_usage, 20) / 20.0 * 35

    +

    -- Session Duration (Maximum = 120 minutes)
    LEAST(session_duration, 120) / 120.0 * 20

    +

    -- Last Login Days Ago (Lower is Better)
    (30 - LEAST(last_login_days_ago, 30)) / 30.0 * 10
)::NUMERIC,
2
);


SELECT *
FROM customer_churn_clean;

SELECT COUNT(*) 
FROM information_schema.columns
WHERE table_name = 'customer_churn_clean';

SELECT *
FROM dim_customers;

SELECT *
FROM dim_date;

SELECT *
FROM fact_payment_attempts;

SELECT *
FROM fact_support_tickets;

SELECT *
FROM fact_surveys;

SELECT *
FROM fact_usage_monthly;

SELECT matviewname 
FROM pg_matviews 
WHERE schemaname = 'public';

ALTER TABLE fact_surveys
ADD COLUMN engagement_score NUMERIC(5,2);

UPDATE fact_surveys
SET engagement_score = ROUND(
    (
        -- Normalize csat_score (1-5) to 0-100
        ((csat_score - 1) / 4.0 * 100)
        +
        -- Normalize nps_score (-100 to 100) to 0-100
        ((nps_score + 100) / 200.0 * 100)
    ) / 2.0
, 2);

SELECT survey_id, csat_score, nps_score, engagement_score
FROM fact_surveys
ORDER BY survey_id
LIMIT 20;


UPDATE customer_churn_clean AS c
SET engagement_score = sub.avg_engagement
FROM (
    SELECT
        customer_id,
        ROUND(AVG(engagement_score), 2) AS avg_engagement
    FROM
        fact_surveys
    GROUP BY
        customer_id
) AS sub
WHERE
    c.customer_id = sub.customer_id;


SELECT customer_id, engagement_score
FROM customer_churn_clean
ORDER BY customer_id
LIMIT 20;


SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'dim_date'
ORDER BY ordinal_position;


CREATE TABLE fact_customer_monthly_snapshot AS
WITH spine AS (
    SELECT
        c.customer_id,
        d.date_key::date AS snapshot_month,
        DATE_TRUNC('month', d.date_key)::date AS snapshot_month_start
    FROM dim_customers c
    JOIN dim_date d
        ON d.date_key BETWEEN DATE_TRUNC('month', c.sign_up_date)
                           AND COALESCE(c.churn_date, CURRENT_DATE)
    WHERE d.date_key = DATE_TRUNC('month', d.date_key)::date  -- keep only month-start rows
)
SELECT DISTINCT customer_id, snapshot_month_start AS snapshot_month
FROM spine;

select *
from dim_cusromers;


ALTER TABLE fact_customer_monthly_snapshot ADD COLUMN tenure_months_at_snapshot INT;

UPDATE fact_customer_monthly_snapshot s
SET tenure_months_at_snapshot =
    (EXTRACT(YEAR FROM AGE(s.snapshot_month, c.sign_up_date)) * 12
     + EXTRACT(MONTH FROM AGE(s.snapshot_month, c.sign_up_date)))::int
FROM dim_customers c
WHERE c.customer_id = s.customer_id;


ALTER TABLE fact_customer_monthly_snapshot
    ADD COLUMN engagement_score_current NUMERIC,
    ADD COLUMN engagement_score_3mo_avg NUMERIC,
    ADD COLUMN engagement_score_trend NUMERIC;


-- 02. clean_and_transform_data.


-- ============================================================
-- 02_clean_and_transform.sql
-- Cleans customer_churn_raw and builds customer_churn_clean.
-- Mirrors the Power Query steps in Section 2 of the report,
-- as SQL so it runs natively in PostgreSQL/pgAdmin.
-- ============================================================

-- ---------------------------------------------------------
-- STEP A: Validation checks (read-only — run first, review output)
-- ---------------------------------------------------------

-- Row count check (expect 10000)
SELECT COUNT(*) AS row_count FROM customer_churn_raw;

-- Duplicate customer_id check (expect 0)
SELECT customer_id, COUNT(*)
FROM customer_churn_raw
GROUP BY customer_id
HAVING COUNT(*) > 1;

-- Categorical domain check — flags unexpected values in key columns
SELECT DISTINCT customer_segment FROM customer_churn_raw;
SELECT DISTINCT contract_type FROM customer_churn_raw;
SELECT DISTINCT churn FROM customer_churn_raw;               -- expect only 0, 1

-- City/country relationship check — confirms the mismatch flagged in the report
SELECT country, COUNT(DISTINCT city) AS distinct_cities
FROM customer_churn_raw
GROUP BY country;

-- If every country shows the same distinct_cities count (7), city is not
-- geographically tied to country — do not use city for geographic analysis.

-- Range/logic check — impossible values
SELECT *
FROM customer_churn_raw
WHERE age NOT BETWEEN 18 AND 90
   OR tenure_months < 0
   OR csat_score NOT BETWEEN 1 AND 5
   OR monthly_logins < 0
   OR weekly_active_days < 0;

   

-- ---------------------------------------------------------
-- STEP B: Build the cleaned, analysis-ready table
-- ---------------------------------------------------------
DROP TABLE IF EXISTS customer_churn_clean;

CREATE TABLE customer_churn_clean AS
WITH iqr AS
(
    SELECT
        percentile_cont(0.25)
            WITHIN GROUP (ORDER BY total_revenue) AS q1,
        percentile_cont(0.75)
            WITHIN GROUP (ORDER BY total_revenue) AS q3
    FROM customer_churn_raw
)
SELECT
    r.customer_id,
    INITCAP(TRIM(r.gender)) AS gender,
    r.age,
    INITCAP(TRIM(r.country)) AS country,
    INITCAP(TRIM(r.city)) AS city,
    INITCAP(TRIM(r.customer_segment)) AS customer_segment,
    r.tenure_months,
    INITCAP(TRIM(r.signup_channel)) AS signup_channel,
    INITCAP(TRIM(r.contract_type)) AS contract_type,
    r.monthly_logins,
    r.weekly_active_days,
    r.avg_session_time,
    r.features_used,
    r.usage_growth_rate,
    r.last_login_days_ago,
    r.monthly_fee,
    r.total_revenue,
    INITCAP(TRIM(r.payment_method)) AS payment_method,
    r.payment_failures,
    (TRIM(r.discount_applied) = 'Yes') AS discount_applied,
    (TRIM(r.price_increase_last_3m) = 'Yes') AS price_increase_last_3m,
    r.support_tickets,
    r.avg_resolution_time,
    COALESCE(NULLIF(TRIM(r.complaint_type), ''), 'No Complaint')
        AS complaint_type,
    (
        TRIM(COALESCE(r.complaint_type,'')) = ''
    ) AS has_complaint_was_null,
    r.csat_score,
    r.escalations,
    r.email_open_rate,
    r.marketing_click_rate,
    r.nps_score,
    INITCAP(TRIM(r.survey_response)) AS survey_response,
    r.referral_count,
    r.churn,
    CASE
        WHEN r.tenure_months <= 6 THEN '0-6 months'
        WHEN r.tenure_months <= 12 THEN '7-12 months'
        WHEN r.tenure_months <= 24 THEN '13-24 months'
        WHEN r.tenure_months <= 36 THEN '25-36 months'
        ELSE '37+ months'
    END AS tenure_bucket,
    CASE
        WHEN r.last_login_days_ago <= 3 THEN '0-3 days'
        WHEN r.last_login_days_ago <= 7 THEN '4-7 days'
        WHEN r.last_login_days_ago <= 14 THEN '8-14 days'
        WHEN r.last_login_days_ago <= 30 THEN '15-30 days'
        ELSE '31+ days'
    END AS login_recency_bucket,
    CASE
        WHEN r.monthly_fee <= 20 THEN 'Low'
        WHEN r.monthly_fee <= 50 THEN 'Mid'
        ELSE 'High'
    END AS revenue_band,
    (r.payment_failures >= 1) AS payment_risk_flag,
    (r.csat_score <= 2) AS low_csat_flag,
    (r.monthly_logins <= 5) AS low_login_flag,
    (r.last_login_days_ago > 30) AS inactive_30d_flag,
    CASE
        WHEN r.tenure_months <= 6
             AND (r.monthly_logins <= 5
             OR r.last_login_days_ago > 30)
        THEN 'Critical'
        WHEN r.csat_score <= 2
             OR r.payment_failures >= 1
        THEN 'High'
        WHEN r.tenure_months <= 6
        THEN 'Elevated'
        ELSE 'Baseline'
    END AS risk_tier,
    (
        r.total_revenue <
        (iqr.q1 - 1.5 * (iqr.q3 - iqr.q1))
        OR
        r.total_revenue >
        (iqr.q3 + 1.5 * (iqr.q3 - iqr.q1))
    ) AS revenue_outlier_flag
FROM customer_churn_raw r 
CROSS JOIN iqr;

-- ---------------------------------------------------------
-- STEP C: Post-build QC checks
-- ---------------------------------------------------------

SELECT COUNT(*) AS clean_row_count FROM customer_churn_clean;       -- expect 10000
SELECT COUNT(*) FROM customer_churn_clean WHERE complaint_type IS NULL; -- expect 0
SELECT risk_tier, COUNT(*), ROUND(AVG(churn)::numeric, 4) AS churn_rate
FROM customer_churn_clean
GROUP BY risk_tier
ORDER BY churn_rate DESC;

-- customer_churn_clean is now the table to point Power BI / further SQL analysis at.

SELECT COUNT(*)
FROM customer_churn_clean;

SELECT COUNT(*)
FROM customer_churn_raw;

CREATE TABLE customer_churn_clean AS
SELECT *
FROM customer_churn_raw;

SELECT COUNT(*)
FROM customer_churn_clean;


SELECT *
FROM customer_churn_raw;

DROP TABLE IF EXISTS customer_churn_clean;

CREATE TABLE customer_churn_clean AS
SELECT *
FROM customer_churn_raw;

SELECT COUNT(*)
FROM customer_churn_clean;


SELECT *
FROM customer_churn_clean;

-- ============================================================
-- NEW / ALTERED TABLES TO CLOSE THE GAPS IDENTIFIED IN
-- saas_churn_table_mapping.md
--
-- Covers 4 gaps:
--   1. Monthly engagement time series   -> fact_engagement_monthly
--   2. Composite risk score              -> ALTER fact_customer_monthly_snapshot
--   3. Churn prediction output            -> fact_churn_predictions
--   4. Ticket categorization/theme        -> dim_complaint_theme + ALTER fact_support_tickets
--
-- ⚠️ = an assumption about column names/types in your existing
-- tables. Check these against your real schema before running.
-- ============================================================


-- ============================================================
-- 1. fact_engagement_monthly
-- Purpose: gives you a real month-over-month engagement metric,
-- which is what the diagnostic questions about "decline" and
-- "trend" actually need. customer_churn_clean's engagement_score
-- is static (one row per customer), so it can't answer these.
-- ============================================================

CREATE TABLE fact_engagement_monthly (
    customer_id        INT         NOT NULL,   -- ⚠️ match type/name to dim_customers.customer_id
    usage_month         DATE        NOT NULL,   -- first day of month, e.g. 2026-06-01
    login_count          INT,                    -- ⚠️ adjust to whatever raw usage signals you actually log
    feature_usage_count  INT,
    session_duration_avg NUMERIC(10,2),
    engagement_score     NUMERIC(6,2),           -- computed composite of the above, 0-100 scale (your call)
    created_at           TIMESTAMP   DEFAULT now(),
    PRIMARY KEY (customer_id, usage_month)
);

-- Example population logic (adjust source columns to match fact_usage_monthly):
--
-- INSERT INTO fact_engagement_monthly (customer_id, usage_month, login_count, feature_usage_count, session_duration_avg, engagement_score)
-- SELECT
--     f.customer_id,
--     DATE_TRUNC('month', f.usage_date)::date AS usage_month,   -- ⚠️ confirm actual date column name in fact_usage_monthly
--     SUM(f.login_count),                                        -- ⚠️ confirm this column exists
--     SUM(f.feature_usage_count),                                -- ⚠️ confirm this column exists
--     AVG(f.session_duration),
--     -- simple weighted composite; tune weights as needed
--     (0.4 * SUM(f.login_count) + 0.4 * SUM(f.feature_usage_count) + 0.2 * AVG(f.session_duration))
-- FROM fact_usage_monthly f
-- GROUP BY f.customer_id, DATE_TRUNC('month', f.usage_date);


-- ============================================================
-- 2. ALTER fact_customer_monthly_snapshot
-- Purpose: adds the composite risk score. This table is already
-- your "current state per customer" table (it holds
-- engagement_score_current / _3mo_avg / _trend from earlier),
-- so risk fields belong here rather than in a new table.
-- ============================================================

ALTER TABLE fact_customer_monthly_snapshot
    ADD COLUMN ticket_volume_score      NUMERIC(6,2),   -- normalized 0-100, higher = more tickets than peers
    ADD COLUMN payment_failure_score    NUMERIC(6,2),   -- normalized 0-100, higher = more failures
    ADD COLUMN composite_risk_score     NUMERIC(6,2),   -- weighted blend of engagement + tickets + payment failure
    ADD COLUMN risk_tier                VARCHAR(20);    -- e.g. 'low' / 'medium' / 'high'


-- ============================================================
-- 3. fact_churn_predictions
-- Purpose: stores model output over time (not just "current"),
-- so you can track prediction drift and measure model accuracy
-- retrospectively. A separate append-only table is standard
-- practice for this rather than overwriting a single "current"
-- column, since you'll want history once the model is live.
-- ============================================================

CREATE TABLE fact_churn_predictions (
    prediction_id        SERIAL      PRIMARY KEY,
    customer_id           INT         NOT NULL,   -- ⚠️ match type/name to dim_customers.customer_id
    scored_at              TIMESTAMP   NOT NULL DEFAULT now(),
    churn_probability_30d  NUMERIC(5,4),           -- 0.0000 - 1.0000
    churn_probability_60d  NUMERIC(5,4),
    churn_probability_90d  NUMERIC(5,4),
    predicted_risk_tier    VARCHAR(20),            -- e.g. 'low' / 'medium' / 'high'
    model_version           VARCHAR(50),            -- track which model produced this, for auditing
    top_features             JSONB                   -- optional: store top contributing features per prediction
);

CREATE INDEX idx_churn_predictions_customer_date
    ON fact_churn_predictions (customer_id, scored_at DESC);

-- Note: this table is only usable once you've trained a churn model
-- (e.g. logistic regression / gradient boosting) on features drawn
-- from fact_engagement_monthly, fact_support_tickets, and
-- fact_payment_attempts. The DDL above is just where the model's
-- output would land — it doesn't generate predictions itself.


-- ============================================================
-- 4. dim_complaint_theme + ALTER fact_support_tickets
-- Purpose: enables "which complaint themes correlate with churn"
-- and "which complaint themes justify dedicated playbooks."
-- Only needed if fact_support_tickets does NOT already have a
-- clean category/theme column — ⚠️ confirm this first; if it
-- already has one, skip this section entirely.
-- ============================================================

CREATE TABLE dim_complaint_theme (
    theme_id      SERIAL      PRIMARY KEY,
    theme_name     VARCHAR(100) NOT NULL UNIQUE,   -- e.g. 'billing_confusion', 'feature_missing', 'bug_report'
    theme_group     VARCHAR(50)                     -- optional higher-level grouping, e.g. 'product' / 'billing' / 'support_quality'
);

ALTER TABLE fact_support_tickets
    ADD COLUMN theme_id INT REFERENCES dim_complaint_theme(theme_id);

-- If tickets currently only have free-text descriptions, theme_id
-- would need to be populated via manual tagging or an NLP
-- classification step — that's a separate workstream, not a query.


-- ============================================================
-- SUMMARY OF WHAT EACH ADDITION UNLOCKS
-- ============================================================
-- fact_engagement_monthly       -> engagement decline/trend questions (Diagnostic §2)
-- fact_customer_monthly_snapshot (altered) -> composite risk, risk tiers (Risk §3)
-- fact_churn_predictions        -> all of Predictive §4
-- dim_complaint_theme (+ alter) -> complaint-theme correlation & playbooks (Diagnostic §2, Prescriptive §5)



-- Step 1: Rename the old table instead of dropping it outright (keeps data safe as a backup)
ALTER TABLE fact_customer_monthly_snapshot RENAME TO fact_customer_monthly_snapshot_old;

-- Step 2: Create the new table with the full known schema
CREATE TABLE fact_customer_monthly_snapshot (
    customer_id                INT             NOT NULL,   -- ⚠️ confirm type matches dim_customers.customer_id
    snapshot_month              DATE            NOT NULL,
    engagement_score_current     NUMERIC(6,2),
    engagement_score_3mo_avg     NUMERIC(6,2),
    engagement_score_trend       NUMERIC(6,2),
    ticket_volume_score            NUMERIC(6,2),
    payment_failure_score          NUMERIC(6,2),
    composite_risk_score           NUMERIC(6,2),
    risk_tier                       VARCHAR(20),
    PRIMARY KEY (customer_id, snapshot_month)
);

-- Step 3: Once you've confirmed the new table has everything you need,
-- copy over any data you still want from the old one, e.g.:
-- INSERT INTO fact_customer_monthly_snapshot (customer_id, snapshot_month, engagement_score_current, ...)
-- SELECT customer_id, snapshot_month, engagement_score_current, ...
-- FROM fact_customer_monthly_snapshot_old;

-- Step 4: Only once you're 100% sure you don't need the old data:
-- DROP TABLE fact_customer_monthly_snapshot_old;


SELECT *
FROM fact_customer_monthly_snapshot;



ALTER TABLE fact_customer_monthly_snapshot
    ADD COLUMN ticket_volume_score      NUMERIC(6,2),
    ADD COLUMN payment_failure_score    NUMERIC(6,2),
    ADD COLUMN composite_risk_score     NUMERIC(6,2),
    ADD COLUMN risk_tier                VARCHAR(20);



SELECT pid, state, wait_event_type, wait_event, now() - query_start AS running_for, query
FROM pg_stat_activity
WHERE query ILIKE '%fact_customer_monthly_snapshot%'
   OR state = 'idle in transaction'
ORDER BY query_start;


SELECT pg_terminate_backend(23152);

ALTER TABLE fact_customer_monthly_snapshot
    ADD COLUMN ticket_volume_score      NUMERIC(6,2),
    ADD COLUMN payment_failure_score    NUMERIC(6,2),
    ADD COLUMN composite_risk_score     NUMERIC(6,2),
    ADD COLUMN risk_tier                VARCHAR(20);


CREATE INDEX idx_fact_usage_monthly_customer_month
    ON fact_usage_monthly (customer_id, usage_month);


SELECT *
FROM fact_customer_monthly_snapshot;

SELECT *
FROM dim_complaint_theme;

select *
from fact_churn_predictions;

SELECT *
from fact_engagement_monthly;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'customer_ch'
ORDER BY ordinal_position;




-- Fix the customer_id type, since the table is empty
DROP TABLE IF EXISTS fact_engagement_monthly;

CREATE TABLE fact_engagement_monthly (
    customer_id           TEXT        NOT NULL,
    usage_month            DATE        NOT NULL,
    monthly_logins           INT,
    weekly_active_days        INT,
    avg_session_time            NUMERIC,
    features_used                 INT,
    usage_growth_rate               NUMERIC,
    last_login_days_ago                INT,
    engagement_score                     NUMERIC(6,2),
    PRIMARY KEY (customer_id, usage_month)
);


INSERT INTO fact_engagement_monthly (
    customer_id, usage_month, monthly_logins, weekly_active_days,
    avg_session_time, features_used, usage_growth_rate, last_login_days_ago,
    engagement_score
)
SELECT
    customer_id,
    usage_month,
    monthly_logins,
    weekly_active_days,
    avg_session_time,
    features_used,
    usage_growth_rate,
    last_login_days_ago,
    -- Composite score, 0-100 scale (weights are a starting point — tune as needed)
    ROUND(
        LEAST(100, GREATEST(0,
              0.30 * LEAST(100, monthly_logins * 5)
            + 0.20 * LEAST(100, weekly_active_days * 14.3)   -- max 7 days/week -> scaled to 100
            + 0.20 * LEAST(100, features_used * 10)
            + 0.15 * LEAST(100, avg_session_time)
            + 0.15 * GREATEST(0, 100 - last_login_days_ago * 3)  -- recency: more days since login = lower score
        ))
    , 2) AS engagement_score
FROM fact_usage_monthly;


SELECT *
FROM fact_engagement_monthly;


UPDATE fact_customer_monthly_snapshot s
SET engagement_score_current = cur.engagement_score,
    engagement_score_3mo_avg = trail_avg.avg_score,
    engagement_score_trend    = cur.engagement_score - trail_avg.avg_score
FROM fact_engagement_monthly cur
LEFT JOIN LATERAL (
    SELECT AVG(m2.engagement_score) AS avg_score
    FROM fact_engagement_monthly m2
    WHERE m2.customer_id = cur.customer_id
      AND m2.usage_month BETWEEN cur.usage_month - INTERVAL '3 months'
                              AND cur.usage_month - INTERVAL '1 month'
) trail_avg ON TRUE
WHERE s.customer_id = cur.customer_id
  AND s.snapshot_month = cur.usage_month;



CREATE INDEX idx_fact_engagement_monthly_customer_month
    ON fact_engagement_monthly (customer_id, usage_month);

SELECT customer_id, snapshot_month, engagement_score_current, engagement_score_3mo_avg, engagement_score_trend
FROM fact_customer_monthly_snapshot
WHERE engagement_score_current IS NOT NULL
ORDER BY snapshot_month
LIMIT 20;


SELECT customer_id, snapshot_month, engagement_score_current, engagement_score_3mo_avg, engagement_score_trend
FROM fact_customer_monthly_snapshot
WHERE engagement_score_3mo_avg IS NOT NULL
ORDER BY snapshot_month
LIMIT 20;


SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fact_support_tickets'
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fact_payment_attempts'
ORDER BY ordinal_position;


CREATE TABLE dim_complaint_theme (
    theme_id      SERIAL      PRIMARY KEY,
    theme_name     VARCHAR(100) NOT NULL UNIQUE,   -- e.g. 'billing_confusion', 'feature_missing', 'bug_report'
    theme_group     VARCHAR(50)                     -- optional grouping, e.g. 'product' / 'billing' / 'support_quality'
);

SELECT * FROM dim_complaint_theme;

CREATE TABLE fact_churn_predictions (
    prediction_id          SERIAL      PRIMARY KEY,
    customer_id              TEXT        NOT NULL,
    scored_at                  TIMESTAMP   NOT NULL DEFAULT now(),
    churn_probability_30d       NUMERIC(5,4),
    churn_probability_60d       NUMERIC(5,4),
    churn_probability_90d       NUMERIC(5,4),
    predicted_risk_tier          VARCHAR(20),
    model_version                  VARCHAR(50),
    top_features                     JSONB
);

CREATE INDEX idx_churn_predictions_customer_date
    ON fact_churn_predictions (customer_id, scored_at DESC);
	
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fact_support_tickets'
ORDER BY ordinal_position;


INSERT INTO dim_complaint_theme (theme_name)
SELECT DISTINCT complaint_type
FROM fact_support_tickets
WHERE complaint_type IS NOT NULL
ON CONFLICT (theme_name) DO NOTHING;

UPDATE fact_support_tickets t
SET theme_id = d.theme_id
FROM dim_complaint_theme d
WHERE t.complaint_type = d.theme_name
  AND t.theme_id IS NULL;


SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fact_payment_attempts'
ORDER BY ordinal_position;

SELECT DISTINCT status FROM fact_payment_attempts;

CREATE INDEX idx_fact_support_tickets_customer_date
    ON fact_support_tickets (customer_id, ticket_date);

CREATE INDEX idx_fact_payment_attempts_customer_date
    ON fact_payment_attempts (customer_id, payment_date);


UPDATE fact_customer_monthly_snapshot s
SET ticket_volume_score   = LEAST(100, COALESCE(t.ticket_count, 0) * 10),
    payment_failure_score = LEAST(100, COALESCE(p.failure_count, 0) * 20),
    composite_risk_score  = ROUND(
        0.35 * (100 - COALESCE(s.engagement_score_current, 50))
      + 0.30 * LEAST(100, COALESCE(t.ticket_count, 0) * 10)
      + 0.35 * LEAST(100, COALESCE(p.failure_count, 0) * 20)
    , 2)
FROM (SELECT customer_id, snapshot_month FROM fact_customer_monthly_snapshot) base
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS ticket_count
    FROM fact_support_tickets ft
    WHERE ft.customer_id = base.customer_id
      AND ft.ticket_date BETWEEN base.snapshot_month - INTERVAL '3 months' AND base.snapshot_month
) t ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS failure_count
    FROM fact_payment_attempts fp
    WHERE fp.customer_id = base.customer_id
      AND fp.status = 'Failed'
      AND fp.payment_date BETWEEN base.snapshot_month - INTERVAL '3 months' AND base.snapshot_month
) p ON TRUE
WHERE s.customer_id = base.customer_id
  AND s.snapshot_month = base.snapshot_month;


UPDATE fact_customer_monthly_snapshot
SET risk_tier = CASE
    WHEN composite_risk_score >= 70 THEN 'high'
    WHEN composite_risk_score >= 40 THEN 'medium'
    ELSE 'low'
END
WHERE composite_risk_score IS NOT NULL;


SELECT risk_tier, COUNT(*), ROUND(AVG(composite_risk_score),2) AS avg_score
FROM fact_customer_monthly_snapshot
GROUP BY risk_tier
ORDER BY avg_score DESC;

INSERT INTO dim_complaint_theme (theme_name)
SELECT DISTINCT complaint_type
FROM fact_support_tickets
WHERE complaint_type IS NOT NULL
ON CONFLICT (theme_name) DO NOTHING;

UPDATE fact_support_tickets t
SET theme_id = d.theme_id
FROM dim_complaint_theme d
WHERE t.complaint_type = d.theme_name
  AND t.theme_id IS NULL;

SELECT
    MIN(ticket_volume_score) AS min_tv, AVG(ticket_volume_score) AS avg_tv, MAX(ticket_volume_score) AS max_tv,
    MIN(payment_failure_score) AS min_pf, AVG(payment_failure_score) AS avg_pf, MAX(payment_failure_score) AS max_pf,
    MIN(composite_risk_score) AS min_composite, AVG(composite_risk_score) AS avg_composite, MAX(composite_risk_score) AS max_composite
FROM fact_customer_monthly_snapshot;

WITH ranked AS (
    SELECT
        customer_id,
        snapshot_month,
        composite_risk_score,
        NTILE(10) OVER (ORDER BY composite_risk_score) AS decile
    FROM fact_customer_monthly_snapshot
    WHERE composite_risk_score IS NOT NULL
)
UPDATE fact_customer_monthly_snapshot s
SET risk_tier = CASE
    WHEN r.decile = 10 THEN 'high'      -- top 10%
    WHEN r.decile >= 7  THEN 'medium'   -- next 30% (deciles 7-9)
    ELSE 'low'                           -- bottom 60%
END
FROM ranked r
WHERE s.customer_id = r.customer_id
  AND s.snapshot_month = r.snapshot_month;


SELECT risk_tier, COUNT(*), ROUND(AVG(composite_risk_score),2) AS avg_score
FROM fact_customer_monthly_snapshot
GROUP BY risk_tier
ORDER BY avg_score DESC;


INSERT INTO dim_complaint_theme (theme_name)
SELECT DISTINCT complaint_type
FROM fact_support_tickets
WHERE complaint_type IS NOT NULL
ON CONFLICT (theme_name) DO NOTHING;


UPDATE fact_support_tickets t
SET theme_id = d.theme_id
FROM dim_complaint_theme d
WHERE t.complaint_type = d.theme_name
  AND t.theme_id IS NULL


SELECT * FROM dim_complaint_theme;

SELECT DISTINCT complaint_type FROM fact_support_tickets LIMIT 20;

SELECT COUNT(*) AS null_theme_count
FROM fact_support_tickets
WHERE theme_id IS NULL;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'customer_churn_clean'
ORDER BY ordinal_position;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fact_churn_predictions'
ORDER BY ordinal_position;

ALTER TABLE fact_churn_predictions
    ALTER COLUMN customer_id TYPE TEXT USING customer_id::TEXT;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'customer_churn_clean'
ORDER BY ordinal_position;


select *
from dim_complaint_theme;

select *
from fact_churn_predictions;

select *
from fact_engagement_monthly;

select *
from fact_customer_monthly_snapshot;

SELECT DISTINCT customer_status, churn FROM customer_churn_clean LIMIT 20;

SELECT
    DATE_TRUNC('month', signup_date + (tenure_months || ' months')::INTERVAL)::date AS churn_month,
    COUNT(*) AS churned_customers
FROM customer_churn_clean
WHERE churn = 1
GROUP BY churn_month
ORDER BY churn_month;

SELECT
    COUNT(*) FILTER (WHERE churn = 1) AS churned_count,
    COUNT(*) AS total_customers,
    ROUND(100.0 * COUNT(*) FILTER (WHERE churn = 1) / COUNT(*), 2) AS churn_rate_pct
FROM customer_churn_clean;


ALTER TABLE fact_customer_monthly_snapshot
ADD COLUMN customer_status VARCHAR(50);

UPDATE fact_customer_monthly_snapshot AS f
SET customer_status = c.customer_status
FROM customer_churn_clean AS c
WHERE f.customer_id = c.customer_id;

SELECT 
    customer_id,
    customer_status
FROM fact_customer_monthly_snapshot
LIMIT 20;

UPDATE fact_customer_monthly_snapshot AS f
SET customer_status = c.customer_status
FROM customer_churn_clean AS c
WHERE f.customer_id = c.customer_id;

SELECT *
FROM fact_customer_monthly_snapshot
WHERE customer_id = 'CUST_00002';

SELECT customer_id, customer_status
FROM customer_churn_clean
WHERE customer_id = 'CUST_00002';

SELECT COUNT(*) AS customer_count
FROM fact_customer_monthly_snapshot
WHERE customer_id = 'CUST_00002';

SELECT 
    customer_status,
    COUNT(*) AS customer_count
FROM fact_customer_monthly_snapshot
GROUP BY customer_status
ORDER BY customer_count DESC;

SELECT COUNT(DISTINCT customer_id) AS churned_customers
FROM fact_customer_monthly_snapshot
WHERE LOWER(TRIM(customer_status)) = 'churned';

SELECT 
    customer_status,
    COUNT(*) AS count
FROM fact_customer_monthly_snapshot
GROUP BY customer_status
ORDER BY count DESC;

SELECT 
    COUNT(DISTINCT customer_id) AS churned_customers
FROM fact_customer_monthly_snapshot
WHERE LOWER(TRIM(customer_status)) = 'churned';

SELECT 
    customer_id,
    snapshot_month,
    customer_status
FROM fact_customer_monthly_snapshot
WHERE LOWER(TRIM(customer_status)) = 'churned'
LIMIT 20;



ALTER TABLE customer_churn_clean
ADD COLUMN arpu NUMERIC(12,2);

UPDATE customer_churn_clean
SET arpu = ROUND(total_revenue::NUMERIC, 2);

ALTER TABLE dim_customers
ADD COLUMN arpu NUMERIC(12,2);

UPDATE dim_customers
SET arpu = ROUND(total_revenue::NUMERIC, 2);

select *
from dim_customers;













