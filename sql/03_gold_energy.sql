-- Fixed invalid identifier: SILVER.POWER_EVENTS watermark filter uses INGESTED_TS, not LOADED_AT.
-- Co-authored with CoCo
-- ============================================================================
-- DE Challenge 2026 — Task 3: Gold Aggregation (Energy Domain)
-- File   : 03_gold_energy.sql
-- Depends: 02_silver_power.sql (SILVER.POWER_EVENTS must be populated)
--
-- Tables created:
--   GOLD.ENERGY_RATE_CONFIG  — peak/off-peak rate lookup
--   GOLD.ENERGY_HOURLY       — hourly kWh per meter (answers Q3)
--   GOLD.ENERGY_DAILY        — daily summary per meter + weekday vs weekend (Q3, Q6)
--
-- Key decisions:
--   • HOURLY_KWH = MAX - MIN of ENERGY_KWH_CUMUL within each (ASSET, hour)
--     per data_dictionary.md guidance. Handles sparse readings naturally.
--   • Exclude IS_ANOMALY = TRUE (PM-F3) from floor-level sums to avoid
--     double-counting with MAIN-MDB.
--   • MAIN-MDB is retained as the "whole-plant" total.
--   • Cost = peak_kwh × 4.50 + offpeak_kwh × 2.60 (฿)
--   • Incremental: SP reads SILVER.POWER_EVENTS with LOADED_AFTER watermark
--     stored in a metadata table, same pattern as other Gold SPs.
-- ============================================================================

USE DATABASE  DE_CHALLENGE;
USE SCHEMA    GOLD;
USE WAREHOUSE CHALLENGE_WH;


-- ============================================================================
-- §1  REFERENCE TABLE — ENERGY_RATE_CONFIG
--     MEA Thailand TOU tariff (Time of Use)
-- ============================================================================

CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.ENERGY_RATE_CONFIG (
    PERIOD_NAME         VARCHAR     NOT NULL,
    IS_PEAK             BOOLEAN     NOT NULL,
    HOUR_START          INTEGER     NOT NULL,   -- local hour (inclusive), 0–23
    HOUR_END            INTEGER     NOT NULL,   -- local hour (exclusive)
    APPLIES_WEEKDAY     BOOLEAN     NOT NULL,
    APPLIES_WEEKEND     BOOLEAN     NOT NULL,
    RATE_BAHT_PER_KWH   FLOAT       NOT NULL,
    NOTES               VARCHAR
)
COMMENT = 'MEA TOU tariff: Peak Mon–Fri 09:00–22:00 local, Off-peak otherwise';

INSERT INTO DE_CHALLENGE.GOLD.ENERGY_RATE_CONFIG VALUES
    ('Peak',     TRUE,  9, 22, TRUE,  FALSE, 4.50,
     'Mon–Fri 09:00–21:59 local (GMT+7)'),
    ('Off-Peak', FALSE, 0,  9, TRUE,  TRUE,  2.60,
     'Weekday 00:00–08:59 + all weekend'),
    ('Off-Peak', FALSE, 22, 24, TRUE, TRUE,  2.60,
     'Weekday 22:00–23:59 + all weekend');


-- ============================================================================
-- §2  GOLD TABLE — ENERGY_HOURLY
--     One row per (ASSET, hour_local)
--     Grain: hourly — feeds ENERGY_DAILY and dashboard trend charts
-- ============================================================================

CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.ENERGY_HOURLY (
    ASSET               VARCHAR         NOT NULL,
    FLOOR_NUM           INTEGER,
    HOUR_LOCAL          TIMESTAMP_NTZ   NOT NULL,   -- truncated to hour, local
    HOUR_UTC            TIMESTAMP_NTZ   NOT NULL,

    -- Energy metrics
    HOURLY_KWH          FLOAT,          -- MAX - MIN of cumulative within hour
    HOURLY_KVARH        FLOAT,
    AVG_ACTIVE_POWER_KW FLOAT,          -- average of instantaneous readings
    AVG_POWER_FACTOR    FLOAT,
    MIN_POWER_FACTOR    FLOAT,          -- worst PF in the hour
    LOW_PF_FLAG         BOOLEAN,        -- TRUE if MIN_POWER_FACTOR < 0.85

    -- Time context
    IS_PEAK_HOUR        BOOLEAN,
    IS_WEEKEND          BOOLEAN,
    SHIFT_NAME          VARCHAR,
    DAY_OF_WEEK         INTEGER,

    -- Cost estimate
    ENERGY_COST_BAHT    FLOAT,          -- HOURLY_KWH × rate

    -- Anomaly
    IS_ANOMALY          BOOLEAN,

    LOADED_AT           TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (ASSET, DATE_TRUNC('DAY', HOUR_LOCAL))
COMMENT = 'Gold — hourly energy per meter, derived from SILVER.POWER_EVENTS';


-- ============================================================================
-- §3  GOLD TABLE — ENERGY_DAILY
--     One row per (ASSET, day_local)
--     Grain: daily — answers Q3 (floor comparison) and Q6 (weekday vs weekend)
-- ============================================================================

CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.ENERGY_DAILY (
    ASSET               VARCHAR         NOT NULL,
    FLOOR_NUM           INTEGER,
    DAY_LOCAL           DATE            NOT NULL,   -- local date (GMT+7)

    -- Energy breakdown
    TOTAL_KWH           FLOAT,          -- sum of hourly kWh
    PEAK_KWH            FLOAT,          -- kWh during peak hours
    OFFPEAK_KWH         FLOAT,          -- kWh during off-peak hours

    -- Cost
    TOTAL_COST_BAHT     FLOAT,          -- PEAK_KWH×4.50 + OFFPEAK_KWH×2.60
    PEAK_COST_BAHT      FLOAT,
    OFFPEAK_COST_BAHT   FLOAT,

    -- Power quality
    AVG_POWER_FACTOR    FLOAT,
    MIN_POWER_FACTOR    FLOAT,
    LOW_PF_HOURS        INTEGER,        -- count of hours with PF < 0.85

    -- Time context
    IS_WEEKEND          BOOLEAN,
    DAY_OF_WEEK         INTEGER,        -- 1=Mon … 7=Sun
    SHIFT_BREAKDOWN     VARIANT,        -- JSON: kWh per shift name

    -- Anomaly
    IS_ANOMALY          BOOLEAN,

    LOADED_AT           TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (ASSET, DAY_LOCAL)
COMMENT = 'Gold — daily energy summary per meter, answers Q3 and Q6';


-- ============================================================================
-- §4  STORED PROCEDURE — SP_LOAD_ENERGY_GOLD
--     SILVER.POWER_EVENTS → GOLD.ENERGY_HOURLY + GOLD.ENERGY_DAILY
-- ============================================================================

CREATE OR REPLACE PROCEDURE DE_CHALLENGE.GOLD.SP_LOAD_ENERGY_GOLD()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Incremental load: SILVER.POWER_EVENTS → GOLD.ENERGY_HOURLY + ENERGY_DAILY'
AS
$$
DECLARE
    v_watermark TIMESTAMP_NTZ;
    v_rows_h    INTEGER;
    v_rows_d    INTEGER;
BEGIN
    -- Watermark: process Silver rows ingested after last run
    SELECT COALESCE(MAX(LOADED_AT), '1970-01-01'::TIMESTAMP_NTZ)
    INTO   :v_watermark
    FROM   DE_CHALLENGE.GOLD.ENERGY_HOURLY;

    -- ── ENERGY_HOURLY ───────────────────────────────────────────────────────
    MERGE INTO DE_CHALLENGE.GOLD.ENERGY_HOURLY AS tgt
    USING (
        SELECT
            ASSET,
            FLOOR_NUM,
            DATE_TRUNC('HOUR', EVENT_TS_LOCAL)          AS HOUR_LOCAL,
            DATE_TRUNC('HOUR', EVENT_TS)                AS HOUR_UTC,
            -- HOURLY_KWH: spread of cumulative counter within the hour
            MAX(ENERGY_KWH_CUMUL) - MIN(ENERGY_KWH_CUMUL)  AS HOURLY_KWH,
            MAX(ENERGY_KVARH_CUMUL) - MIN(ENERGY_KVARH_CUMUL) AS HOURLY_KVARH,
            ROUND(AVG(ACTIVE_POWER_KW), 3)              AS AVG_ACTIVE_POWER_KW,
            ROUND(AVG(POWER_FACTOR), 4)                 AS AVG_POWER_FACTOR,
            ROUND(MIN(POWER_FACTOR), 4)                 AS MIN_POWER_FACTOR,
            MIN(POWER_FACTOR) < 0.85                    AS LOW_PF_FLAG,
            MAX(IS_PEAK_HOUR::INTEGER)::BOOLEAN         AS IS_PEAK_HOUR,
            MAX(IS_WEEKEND::INTEGER)::BOOLEAN           AS IS_WEEKEND,
            MAX(SHIFT_NAME)                             AS SHIFT_NAME,
            MAX(DAY_OF_WEEK)                            AS DAY_OF_WEEK,
            -- Cost per hour
            ROUND(
                (MAX(ENERGY_KWH_CUMUL) - MIN(ENERGY_KWH_CUMUL)) *
                CASE WHEN MAX(IS_PEAK_HOUR::INTEGER) = 1 THEN 4.50 ELSE 2.60 END
            , 2)                                        AS ENERGY_COST_BAHT,
            MAX(IS_ANOMALY::INTEGER)::BOOLEAN           AS IS_ANOMALY
        FROM DE_CHALLENGE.SILVER.POWER_EVENTS
        WHERE INGESTED_TS > :v_watermark
        GROUP BY ASSET, FLOOR_NUM, DATE_TRUNC('HOUR', EVENT_TS_LOCAL),
                 DATE_TRUNC('HOUR', EVENT_TS)
        HAVING (MAX(ENERGY_KWH_CUMUL) - MIN(ENERGY_KWH_CUMUL)) >= 0
    ) AS src
    ON  tgt.ASSET       = src.ASSET
    AND tgt.HOUR_LOCAL  = src.HOUR_LOCAL

    WHEN MATCHED THEN UPDATE SET
        tgt.HOURLY_KWH          = src.HOURLY_KWH,
        tgt.HOURLY_KVARH        = src.HOURLY_KVARH,
        tgt.AVG_ACTIVE_POWER_KW = src.AVG_ACTIVE_POWER_KW,
        tgt.AVG_POWER_FACTOR    = src.AVG_POWER_FACTOR,
        tgt.MIN_POWER_FACTOR    = src.MIN_POWER_FACTOR,
        tgt.LOW_PF_FLAG         = src.LOW_PF_FLAG,
        tgt.ENERGY_COST_BAHT    = src.ENERGY_COST_BAHT,
        tgt.LOADED_AT           = CURRENT_TIMESTAMP()

    WHEN NOT MATCHED THEN INSERT (
        ASSET, FLOOR_NUM, HOUR_LOCAL, HOUR_UTC,
        HOURLY_KWH, HOURLY_KVARH, AVG_ACTIVE_POWER_KW,
        AVG_POWER_FACTOR, MIN_POWER_FACTOR, LOW_PF_FLAG,
        IS_PEAK_HOUR, IS_WEEKEND, SHIFT_NAME, DAY_OF_WEEK,
        ENERGY_COST_BAHT, IS_ANOMALY, LOADED_AT
    ) VALUES (
        src.ASSET, src.FLOOR_NUM, src.HOUR_LOCAL, src.HOUR_UTC,
        src.HOURLY_KWH, src.HOURLY_KVARH, src.AVG_ACTIVE_POWER_KW,
        src.AVG_POWER_FACTOR, src.MIN_POWER_FACTOR, src.LOW_PF_FLAG,
        src.IS_PEAK_HOUR, src.IS_WEEKEND, src.SHIFT_NAME, src.DAY_OF_WEEK,
        src.ENERGY_COST_BAHT, src.IS_ANOMALY, CURRENT_TIMESTAMP()
    );

    v_rows_h := SQLROWCOUNT;

    -- ── ENERGY_DAILY ────────────────────────────────────────────────────────
    MERGE INTO DE_CHALLENGE.GOLD.ENERGY_DAILY AS tgt
    USING (
        SELECT
            ASSET,
            FLOOR_NUM,
            DATE_TRUNC('DAY', HOUR_LOCAL)::DATE         AS DAY_LOCAL,
            ROUND(SUM(HOURLY_KWH), 2)                   AS TOTAL_KWH,
            ROUND(SUM(CASE WHEN IS_PEAK_HOUR THEN HOURLY_KWH ELSE 0 END), 2)
                                                        AS PEAK_KWH,
            ROUND(SUM(CASE WHEN NOT IS_PEAK_HOUR THEN HOURLY_KWH ELSE 0 END), 2)
                                                        AS OFFPEAK_KWH,
            ROUND(SUM(CASE WHEN IS_PEAK_HOUR THEN HOURLY_KWH * 4.50 ELSE 0 END), 2)
                                                        AS PEAK_COST_BAHT,
            ROUND(SUM(CASE WHEN NOT IS_PEAK_HOUR THEN HOURLY_KWH * 2.60 ELSE 0 END), 2)
                                                        AS OFFPEAK_COST_BAHT,
            ROUND(
                SUM(CASE WHEN IS_PEAK_HOUR    THEN HOURLY_KWH * 4.50 ELSE 0 END) +
                SUM(CASE WHEN NOT IS_PEAK_HOUR THEN HOURLY_KWH * 2.60 ELSE 0 END)
            , 2)                                        AS TOTAL_COST_BAHT,
            ROUND(AVG(AVG_POWER_FACTOR), 4)             AS AVG_POWER_FACTOR,
            ROUND(MIN(MIN_POWER_FACTOR), 4)             AS MIN_POWER_FACTOR,
            SUM(LOW_PF_FLAG::INTEGER)                   AS LOW_PF_HOURS,
            MAX(IS_WEEKEND::INTEGER)::BOOLEAN           AS IS_WEEKEND,
            MAX(DAY_OF_WEEK)                            AS DAY_OF_WEEK,
            OBJECT_CONSTRUCT(
                'Day',      ROUND(SUM(CASE WHEN SHIFT_NAME = 'Day'      THEN HOURLY_KWH ELSE 0 END), 2),
                'Day OT',   ROUND(SUM(CASE WHEN SHIFT_NAME = 'Day OT'   THEN HOURLY_KWH ELSE 0 END), 2),
                'Night',    ROUND(SUM(CASE WHEN SHIFT_NAME = 'Night'    THEN HOURLY_KWH ELSE 0 END), 2),
                'Night OT', ROUND(SUM(CASE WHEN SHIFT_NAME = 'Night OT' THEN HOURLY_KWH ELSE 0 END), 2)
            )                                           AS SHIFT_BREAKDOWN,
            MAX(IS_ANOMALY::INTEGER)::BOOLEAN           AS IS_ANOMALY
        FROM DE_CHALLENGE.GOLD.ENERGY_HOURLY
        WHERE LOADED_AT > :v_watermark
        GROUP BY ASSET, FLOOR_NUM, DATE_TRUNC('DAY', HOUR_LOCAL)::DATE
    ) AS src
    ON  tgt.ASSET     = src.ASSET
    AND tgt.DAY_LOCAL = src.DAY_LOCAL

    WHEN MATCHED THEN UPDATE SET
        tgt.TOTAL_KWH           = src.TOTAL_KWH,
        tgt.PEAK_KWH            = src.PEAK_KWH,
        tgt.OFFPEAK_KWH         = src.OFFPEAK_KWH,
        tgt.PEAK_COST_BAHT      = src.PEAK_COST_BAHT,
        tgt.OFFPEAK_COST_BAHT   = src.OFFPEAK_COST_BAHT,
        tgt.TOTAL_COST_BAHT     = src.TOTAL_COST_BAHT,
        tgt.AVG_POWER_FACTOR    = src.AVG_POWER_FACTOR,
        tgt.MIN_POWER_FACTOR    = src.MIN_POWER_FACTOR,
        tgt.LOW_PF_HOURS        = src.LOW_PF_HOURS,
        tgt.SHIFT_BREAKDOWN     = src.SHIFT_BREAKDOWN,
        tgt.LOADED_AT           = CURRENT_TIMESTAMP()

    WHEN NOT MATCHED THEN INSERT (
        ASSET, FLOOR_NUM, DAY_LOCAL,
        TOTAL_KWH, PEAK_KWH, OFFPEAK_KWH,
        TOTAL_COST_BAHT, PEAK_COST_BAHT, OFFPEAK_COST_BAHT,
        AVG_POWER_FACTOR, MIN_POWER_FACTOR, LOW_PF_HOURS,
        IS_WEEKEND, DAY_OF_WEEK, SHIFT_BREAKDOWN, IS_ANOMALY, LOADED_AT
    ) VALUES (
        src.ASSET, src.FLOOR_NUM, src.DAY_LOCAL,
        src.TOTAL_KWH, src.PEAK_KWH, src.OFFPEAK_KWH,
        src.TOTAL_COST_BAHT, src.PEAK_COST_BAHT, src.OFFPEAK_COST_BAHT,
        src.AVG_POWER_FACTOR, src.MIN_POWER_FACTOR, src.LOW_PF_HOURS,
        src.IS_WEEKEND, src.DAY_OF_WEEK, src.SHIFT_BREAKDOWN,
        src.IS_ANOMALY, CURRENT_TIMESTAMP()
    );

    v_rows_d := SQLROWCOUNT;

    RETURN 'SP_LOAD_ENERGY_GOLD completed — ENERGY_HOURLY: ' || v_rows_h ||
           ' rows, ENERGY_DAILY: ' || v_rows_d || ' rows.';

EXCEPTION
    WHEN OTHER THEN
        RAISE;
END;
$$;


-- ============================================================================
-- §5  TASK — TASK_LOAD_ENERGY_GOLD
-- ============================================================================

CREATE OR REPLACE TASK DE_CHALLENGE.GOLD.TASK_LOAD_ENERGY_GOLD
    WAREHOUSE   = CHALLENGE_WH
    SCHEDULE    = '60 MINUTE'
    COMMENT     = 'Runs SP_LOAD_ENERGY_GOLD every hour after Silver power is loaded'
AS
    CALL DE_CHALLENGE.GOLD.SP_LOAD_ENERGY_GOLD();

-- Resume when ready:
-- ALTER TASK DE_CHALLENGE.GOLD.TASK_LOAD_ENERGY_GOLD RESUME;


-- ============================================================================
-- §6  BACKFILL — run once to populate from full Silver history
-- ============================================================================
-- After Silver backfill (02_silver_power.sql §5) completes, run this to
-- populate Gold tables. The SP uses LOADED_AT watermark so it will pick up
-- all rows on first run (watermark = 1970-01-01).
-- ============================================================================

CALL DE_CHALLENGE.GOLD.SP_LOAD_ENERGY_GOLD();


-- ============================================================================
-- §7  VERIFICATION QUERIES — Q3 and Q6
-- ============================================================================

-- Q3a: Which floor uses most energy? (exclude PM-F3 anomaly, exclude MAIN-MDB total)
SELECT
    ASSET,
    FLOOR_NUM,
    ROUND(SUM(TOTAL_KWH), 0)        AS total_kwh,
    ROUND(SUM(TOTAL_COST_BAHT), 0)  AS total_cost_baht,
    ROUND(AVG(AVG_POWER_FACTOR), 3) AS avg_pf
FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
WHERE IS_ANOMALY = FALSE
  AND ASSET != 'MAIN-MDB'
GROUP BY ASSET, FLOOR_NUM
ORDER BY total_kwh DESC;

-- Q3b: Which shift uses most energy? (plant total, exclude anomaly)
SELECT
    d.ASSET,
    h.SHIFT_NAME,
    ROUND(SUM(h.HOURLY_KWH), 0)     AS shift_kwh,
    ROUND(AVG(h.AVG_POWER_FACTOR), 3) AS avg_pf
FROM DE_CHALLENGE.GOLD.ENERGY_HOURLY h
JOIN DE_CHALLENGE.GOLD.ENERGY_DAILY d
    ON h.ASSET = d.ASSET AND DATE_TRUNC('DAY', h.HOUR_LOCAL)::DATE = d.DAY_LOCAL
WHERE h.IS_ANOMALY = FALSE
  AND h.ASSET = 'MAIN-MDB'
GROUP BY d.ASSET, h.SHIFT_NAME
ORDER BY shift_kwh DESC;

-- Q6: Weekday vs weekend energy and cost comparison
SELECT
    IS_WEEKEND,
    CASE WHEN IS_WEEKEND THEN 'Weekend' ELSE 'Weekday' END  AS day_type,
    COUNT(DISTINCT DAY_LOCAL)       AS day_count,
    ROUND(AVG(TOTAL_KWH), 1)        AS avg_daily_kwh,
    ROUND(AVG(TOTAL_COST_BAHT), 0)  AS avg_daily_cost_baht,
    ROUND(
        (MAX(CASE WHEN NOT IS_WEEKEND THEN AVG_TOTAL_KWH END)
         - MAX(CASE WHEN IS_WEEKEND THEN AVG_TOTAL_KWH END))
        / NULLIF(MAX(CASE WHEN NOT IS_WEEKEND THEN AVG_TOTAL_KWH END), 0) * 100
    , 1)                            AS weekday_vs_weekend_pct_diff
FROM (
    SELECT IS_WEEKEND, DAY_LOCAL, TOTAL_KWH, TOTAL_COST_BAHT,
           AVG(TOTAL_KWH) OVER (PARTITION BY IS_WEEKEND) AS AVG_TOTAL_KWH
    FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
    WHERE ASSET = 'MAIN-MDB'
)
GROUP BY IS_WEEKEND
ORDER BY IS_WEEKEND;

-- Power factor alert — meters with avg PF < 0.85
SELECT
    ASSET,
    ROUND(AVG(AVG_POWER_FACTOR), 3)     AS overall_avg_pf,
    SUM(LOW_PF_HOURS)                   AS total_low_pf_hours,
    ROUND(SUM(LOW_PF_HOURS) * 100.0
          / NULLIF(COUNT(*) * 24, 0), 1) AS low_pf_pct_of_time
FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
WHERE IS_ANOMALY = FALSE
GROUP BY ASSET
HAVING AVG(AVG_POWER_FACTOR) < 0.90
ORDER BY overall_avg_pf ASC;
