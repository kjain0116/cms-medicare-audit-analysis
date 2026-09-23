-- ================================================================
-- CMS Medicare Inpatient Audit Analysis — SQL Queries
-- ================================================================
-- Dataset: CMS Medicare Inpatient Hospitals by Provider and Service
-- Source:  data.cms.gov (Provider Summary by Type of Service)
-- Engine:  DuckDB (run against data/processed/cms_clean.csv)
--
-- Purpose: Identify hospitals with anomalous charge-to-payment
--          ratios to support Medicare audit prioritisation.
--
-- Table:   cms  (loaded from cms_clean.csv after the cleaning
--                pipeline in 01_data_cleaning.ipynb)
--
-- Run order: queries are independent and can be run in any order.
-- Executed from notebooks/03_sql_analysis.ipynb via DuckDB.
-- ================================================================


-- ----------------------------------------------------------------
-- Query 1: Overall Charge-to-Payment Ratio Statistics
-- ----------------------------------------------------------------
-- Establishes the baseline distribution across all provider-DRG
-- records. Median is the key figure — the mean is pulled upward
-- by extreme outliers and is less representative of a "typical"
-- hospital.
-- ----------------------------------------------------------------

SELECT
    ROUND(MIN(charge_to_payment_ratio), 2)    AS min_ratio,
    ROUND(AVG(charge_to_payment_ratio), 2)    AS avg_ratio,
    ROUND(MEDIAN(charge_to_payment_ratio), 2) AS median_ratio,
    ROUND(MAX(charge_to_payment_ratio), 2)    AS max_ratio,
    ROUND(STDDEV(charge_to_payment_ratio), 2) AS stddev_ratio
FROM cms
WHERE charge_to_payment_ratio IS NOT NULL;


-- ----------------------------------------------------------------
-- Query 2: Average Ratio by State
-- ----------------------------------------------------------------
-- Surfaces geographic concentration of high-ratio billing.
-- Feeds the choropleth map on Power BI dashboard page 1.
-- ----------------------------------------------------------------

SELECT
    Rndrng_Prvdr_State_Abrvtn                  AS state,
    COUNT(DISTINCT Rndrng_Prvdr_CCN)           AS num_providers,
    ROUND(AVG(charge_to_payment_ratio), 2)     AS avg_ratio,
    ROUND(MEDIAN(charge_to_payment_ratio), 2)  AS median_ratio
FROM cms
WHERE charge_to_payment_ratio IS NOT NULL
GROUP BY Rndrng_Prvdr_State_Abrvtn
ORDER BY avg_ratio DESC;


-- ----------------------------------------------------------------
-- Query 3: Top 10 Highest-Ratio Provider Records
-- ----------------------------------------------------------------
-- The single most "actionable" query in this file — these are
-- literal candidates for audit review. Includes both the charge
-- and Medicare payment figures so the gap is visible at a glance.
-- ----------------------------------------------------------------

SELECT
    Rndrng_Prvdr_CCN                           AS provider_id,
    Rndrng_Prvdr_Org_Name                      AS hospital_name,
    Rndrng_Prvdr_State_Abrvtn                  AS state,
    DRG_Desc                                   AS drg,
    Tot_Dschrgs                                AS discharges,
    ROUND(Avg_Submtd_Cvrd_Chrg, 2)             AS avg_charge,
    ROUND(Avg_Mdcr_Pymt_Amt, 2)                AS avg_medicare_payment,
    ROUND(charge_to_payment_ratio, 2)          AS ratio
FROM cms
WHERE charge_to_payment_ratio IS NOT NULL
ORDER BY charge_to_payment_ratio DESC
LIMIT 10;


-- ----------------------------------------------------------------
-- Query 4: Ratio by DRG Clinical Category
-- ----------------------------------------------------------------
-- DRG codes are grouped into clinical categories using their
-- numeric ranges (CASE WHEN bucketing). Reveals whether certain
-- procedure types are systematically overbilled relative to
-- what Medicare pays out.
-- ----------------------------------------------------------------

SELECT
    CASE
        WHEN CAST(DRG_Cd AS INT) BETWEEN 1   AND 103 THEN 'Nervous System'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 113 AND 145 THEN 'Eye & Ear'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 146 AND 159 THEN 'ENT'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 163 AND 208 THEN 'Respiratory'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 215 AND 316 THEN 'Circulatory'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 326 AND 395 THEN 'Digestive'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 405 AND 446 THEN 'Hepatobiliary'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 453 AND 566 THEN 'Musculoskeletal'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 570 AND 585 THEN 'Skin & Tissue'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 614 AND 645 THEN 'Kidney & Urinary'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 650 AND 700 THEN 'Reproductive'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 734 AND 761 THEN 'Alcohol & Drug'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 800 AND 816 THEN 'Infections'
        WHEN CAST(DRG_Cd AS INT) BETWEEN 870 AND 872 THEN 'Septicaemia'
        ELSE 'Other'
    END                                        AS drg_category,
    COUNT(*)                                   AS records,
    ROUND(AVG(charge_to_payment_ratio), 2)     AS avg_ratio,
    ROUND(MEDIAN(charge_to_payment_ratio), 2)  AS median_ratio,
    ROUND(MAX(charge_to_payment_ratio), 2)     AS max_ratio
FROM cms
WHERE charge_to_payment_ratio IS NOT NULL
GROUP BY drg_category
ORDER BY avg_ratio DESC;


-- ----------------------------------------------------------------
-- Query 5: Volume Tier Analysis (Window Function)
-- ----------------------------------------------------------------
-- Uses a CTE + NTILE(4) window function to split providers into
-- discharge-volume quartiles, then compares average ratio across
-- tiers. Tests whether low-volume providers drive disproportionate
-- ratio inflation.
-- ----------------------------------------------------------------

WITH volume_tiers AS (
    SELECT
        Rndrng_Prvdr_CCN,
        Rndrng_Prvdr_Org_Name,
        Rndrng_Prvdr_State_Abrvtn,
        Tot_Dschrgs,
        charge_to_payment_ratio,
        NTILE(4) OVER (ORDER BY Tot_Dschrgs) AS volume_quartile
    FROM cms
    WHERE charge_to_payment_ratio IS NOT NULL
)
SELECT
    volume_quartile,
    CASE volume_quartile
        WHEN 1 THEN 'Q1 - Lowest Volume'
        WHEN 2 THEN 'Q2 - Low-Mid Volume'
        WHEN 3 THEN 'Q3 - High-Mid Volume'
        WHEN 4 THEN 'Q4 - Highest Volume'
    END                                        AS tier_label,
    COUNT(*)                                   AS records,
    ROUND(AVG(Tot_Dschrgs), 0)                 AS avg_discharges,
    ROUND(AVG(charge_to_payment_ratio), 2)     AS avg_ratio,
    ROUND(MEDIAN(charge_to_payment_ratio), 2)  AS median_ratio,
    ROUND(MAX(charge_to_payment_ratio), 2)     AS max_ratio
FROM volume_tiers
GROUP BY volume_quartile
ORDER BY volume_quartile;


-- ----------------------------------------------------------------
-- Query 6: Statistical Outlier Count by State
-- ----------------------------------------------------------------
-- Uses the ratio_outlier_flag column produced during cleaning
-- (IQR method, floored at 1.0 — see 01_data_cleaning.ipynb,
-- Cell 6B) to count and rank states by outlier concentration.
-- ----------------------------------------------------------------

SELECT
    Rndrng_Prvdr_State_Abrvtn                  AS state,
    COUNT(*)                                   AS total_records,
    SUM(CAST(ratio_outlier_flag AS INT))       AS outlier_records,
    ROUND(
        SUM(CAST(ratio_outlier_flag AS INT)) * 100.0 / COUNT(*), 1
    )                                          AS outlier_pct
FROM cms
GROUP BY Rndrng_Prvdr_State_Abrvtn
ORDER BY outlier_records DESC;


-- ----------------------------------------------------------------
-- Query 7: Revenue at Stake for Outlier Providers, by State
-- ----------------------------------------------------------------
-- The headline financial figure for the business recommendation.
-- total_gap = total charges billed minus total Medicare payments,
-- scoped to records already flagged as statistical outliers.
-- Ranks states by dollar exposure to prioritise audit resourcing.
-- ----------------------------------------------------------------

SELECT
    Rndrng_Prvdr_State_Abrvtn                        AS state,
    COUNT(*)                                         AS outlier_records,
    COUNT(DISTINCT Rndrng_Prvdr_CCN)                 AS outlier_providers,
    ROUND(SUM(Avg_Submtd_Cvrd_Chrg * Tot_Dschrgs), 2) AS total_charges,
    ROUND(SUM(Avg_Mdcr_Pymt_Amt * Tot_Dschrgs), 2)    AS total_medicare_paid,
    ROUND(
        SUM(Avg_Submtd_Cvrd_Chrg * Tot_Dschrgs) -
        SUM(Avg_Mdcr_Pymt_Amt * Tot_Dschrgs), 2
    )                                                AS total_gap
FROM cms
WHERE ratio_outlier_flag = true
GROUP BY Rndrng_Prvdr_State_Abrvtn
ORDER BY total_gap DESC
LIMIT 15;