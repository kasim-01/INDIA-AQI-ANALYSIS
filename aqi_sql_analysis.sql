/* =====================================================================
   India AQI Analysis - SQL layer
   Table: day_wise_aqi_data (one row per city per day)
   Works on MySQL 8+ and PostgreSQL (uses EXTRACT, CTEs, window functions)
   ===================================================================== */

/* ---------- 0. SETUP (MySQL) ----------
CREATE DATABASE aqi_project;
USE aqi_project;

CREATE TABLE day_wise_aqi_data (
    date                          DATE,
    state                         VARCHAR(60),
    area                          VARCHAR(80),
    number_of_monitoring_stations INT,
    prominent_pollutants          VARCHAR(60),
    aqi_value                     INT,
    air_quality_status            VARCHAR(30)
);
-- Import day_wise_aqi_data.csv with MySQL Workbench "Table Data Import Wizard"
-- or: LOAD DATA LOCAL INFILE '...csv' INTO TABLE day_wise_aqi_data
--     FIELDS TERMINATED BY ',' IGNORE 1 LINES;
*/


/* ---------- 1. DATA QUALITY CHECKS ---------- */

-- 1.1 Row count and date range
SELECT COUNT(*) AS total_rows,
       MIN(date) AS first_date,
       MAX(date) AS last_date,
       COUNT(DISTINCT state) AS states,
       COUNT(DISTINCT area)  AS areas
FROM day_wise_aqi_data;

-- 1.2 Missing values per column
SELECT
    SUM(CASE WHEN aqi_value IS NULL THEN 1 ELSE 0 END)                      AS null_aqi,
    SUM(CASE WHEN prominent_pollutants IS NULL THEN 1 ELSE 0 END)           AS null_pollutant,
    SUM(CASE WHEN number_of_monitoring_stations IS NULL THEN 1 ELSE 0 END)  AS null_stations
FROM day_wise_aqi_data;

-- 1.3 Duplicate city-day records
--     NOTE: group by state AND area. Two different cities are both named
--     "Aurangabad" (Bihar and Maharashtra), so area alone shows false duplicates.
SELECT state, area, date, COUNT(*) AS cnt
FROM day_wise_aqi_data
GROUP BY state, area, date
HAVING COUNT(*) > 1;

-- 1.4 Out-of-range AQI values (valid range 0-500)
SELECT COUNT(*) AS invalid_rows
FROM day_wise_aqi_data
WHERE aqi_value < 0 OR aqi_value > 500;

-- 1.5 Monitoring coverage growth by year (explains the trend caveat)
SELECT EXTRACT(YEAR FROM date) AS yr,
       COUNT(DISTINCT area)    AS cities_reporting,
       COUNT(*)                AS records
FROM day_wise_aqi_data
GROUP BY EXTRACT(YEAR FROM date)
ORDER BY yr;


/* ---------- 2. CORE ANALYSIS ---------- */

-- 2.1 Top 10 most polluted states (average AQI)
SELECT top 10 state,
       ROUND(AVG(aqi_value), 1) AS avg_aqi,
       COUNT(*)                 AS records
FROM day_wise_aqi_data
GROUP BY state
ORDER BY avg_aqi DESC

-- 2.2 Top 10 most polluted cities (at least 1 year of data)
SELECT top 10 state, area,
       ROUND(AVG(aqi_value), 1) AS avg_aqi,
       COUNT(*)                 AS records
FROM day_wise_aqi_data
GROUP BY state, area
HAVING COUNT(*) >= 365
ORDER BY avg_aqi DESC

-- 2.3 Seasonality: average AQI by calendar month
SELECT EXTRACT(MONTH FROM date) AS month_no,
       ROUND(AVG(aqi_value), 1) AS avg_aqi
FROM day_wise_aqi_data
GROUP BY EXTRACT(MONTH FROM date)
ORDER BY month_no;

-- 2.4 Share of days in each health category
SELECT CASE
           WHEN aqi_value <= 50  THEN '1 Good'
           WHEN aqi_value <= 100 THEN '2 Moderate'
           WHEN aqi_value <= 150 THEN '3 Poor'
           WHEN aqi_value <= 200 THEN '4 Unhealthy'
           WHEN aqi_value <= 300 THEN '5 Very Unhealthy'
           ELSE                       '6 Hazardous'
       END AS aqi_category,
       COUNT(*) AS days,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM day_wise_aqi_data
GROUP BY 1
ORDER BY 1;

-- 2.5 Most frequent prominent pollutants
SELECT top 8 prominent_pollutants,
       COUNT(*) AS occurrences,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(AVG(aqi_value), 1) AS avg_aqi
FROM day_wise_aqi_data
GROUP BY prominent_pollutants
ORDER BY occurrences DESC



/* ---------- 3. ADVANCED (CTEs + WINDOW FUNCTIONS) ---------- */

-- 3.1 Rank cities within each state by average AQI
WITH city_avg AS (
    SELECT state, area,
           AVG(aqi_value) AS avg_aqi,
           COUNT(*)       AS records
    FROM day_wise_aqi_data
    GROUP BY state, area
    HAVING COUNT(*) >= 365
)
SELECT state, area,
       ROUND(avg_aqi, 1) AS avg_aqi,
       RANK() OVER (PARTITION BY state ORDER BY avg_aqi DESC) AS rank_in_state
FROM city_avg
ORDER BY state, rank_in_state;

-- 3.2 Year-over-year change in AQI for a fixed set of cities
--     (cities with data in every year 2019-2024 -> like-for-like comparison)
WITH yearly AS (
    SELECT state, area,
           EXTRACT(YEAR FROM date) AS yr,
           AVG(aqi_value)          AS avg_aqi
    FROM day_wise_aqi_data
    WHERE EXTRACT(YEAR FROM date) BETWEEN 2019 AND 2024
    GROUP BY state, area, EXTRACT(YEAR FROM date)
),
consistent_cities AS (
    SELECT state, area
    FROM yearly
    GROUP BY state, area
    HAVING COUNT(*) = 6
)
SELECT y.state, y.area, y.yr,
       ROUND(y.avg_aqi, 1) AS avg_aqi,
       ROUND(y.avg_aqi - LAG(y.avg_aqi) OVER (PARTITION BY y.state, y.area ORDER BY y.yr), 1) AS yoy_change
FROM yearly y
JOIN consistent_cities c ON c.state = y.state AND c.area = y.area
ORDER BY y.state, y.area, y.yr;

-- 3.3 Like-for-like national trend (same cities every year, removes coverage bias)
WITH yearly AS (
    SELECT state, area, EXTRACT(YEAR FROM date) AS yr, AVG(aqi_value) AS avg_aqi
    FROM day_wise_aqi_data
    WHERE EXTRACT(YEAR FROM date) BETWEEN 2019 AND 2024
    GROUP BY state, area, EXTRACT(YEAR FROM date)
),
consistent_cities AS (
    SELECT state, area FROM yearly GROUP BY state, area HAVING COUNT(*) = 6
)
SELECT y.yr,
       COUNT(*)                 AS cities,
       ROUND(AVG(y.avg_aqi), 1) AS avg_aqi
FROM yearly y
JOIN consistent_cities c ON c.state = y.state AND c.area = y.area
GROUP BY y.yr
ORDER BY yr;

-- 3.4 30-day moving average AQI for Delhi
SELECT date, aqi_value,
       ROUND(AVG(aqi_value) OVER (ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW), 1) AS ma_30d
FROM day_wise_aqi_data
WHERE area = 'Delhi'
ORDER BY date;

-- 3.5 Worst month for each state (highest monthly average)
WITH monthly AS (
    SELECT state,
           EXTRACT(MONTH FROM date) AS month_no,
           AVG(aqi_value)           AS avg_aqi
    FROM day_wise_aqi_data
    GROUP BY state, EXTRACT(MONTH FROM date)
),
ranked AS (
    SELECT state, month_no, ROUND(avg_aqi, 1) AS avg_aqi,
           ROW_NUMBER() OVER (PARTITION BY state ORDER BY avg_aqi DESC) AS rn
    FROM monthly
)
SELECT state, month_no AS worst_month, avg_aqi
FROM ranked
WHERE rn = 1
ORDER BY avg_aqi DESC;

-- 3.6 Hazardous days (AQI > 300) per city
SELECT top 10 state, area,
       SUM(CASE WHEN aqi_value > 300 THEN 1 ELSE 0 END) AS hazardous_days,
       COUNT(*)                                          AS total_days,
       ROUND(100.0 * SUM(CASE WHEN aqi_value > 300 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_hazardous
FROM day_wise_aqi_data
GROUP BY state, area
HAVING COUNT(*) >= 365
ORDER BY pct_hazardous DESC


-- 3.7 Winter-vs-monsoon gap per city (Nov-Jan vs Jul-Sep)
SELECT top 10 state, area,
       ROUND(AVG(CASE WHEN EXTRACT(MONTH FROM date) IN (11,12,1) THEN aqi_value END), 1) AS winter_avg,
       ROUND(AVG(CASE WHEN EXTRACT(MONTH FROM date) IN (7,8,9)   THEN aqi_value END), 1) AS monsoon_avg,
       ROUND(AVG(CASE WHEN EXTRACT(MONTH FROM date) IN (11,12,1) THEN aqi_value END)
           - AVG(CASE WHEN EXTRACT(MONTH FROM date) IN (7,8,9)   THEN aqi_value END), 1) AS seasonal_gap
FROM day_wise_aqi_data
GROUP BY state, area
HAVING COUNT(*) >= 730
ORDER BY seasonal_gap DESC
