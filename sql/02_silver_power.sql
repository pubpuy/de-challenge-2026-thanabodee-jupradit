-- Fixed CREATE TASK clause order (COMMENT before WHEN) for TASK_LOAD_POWER.
-- Co-authored with CoCo
-- ============================================================================
-- DE Challenge 2026 — Task 2: Silver Pipeline (Power Domain)
-- File   : 02_silver_power.sql
-- Depends: 02_silver_schema.sql context (USE DATABASE / SCHEMA already set)
--
-- Strategy : Stream + Task + MERGE  (Incremental · Idempotent · Typed)
-- Domain   : Power (power_meter.raw.v1)
--
-- Run order:
--   1. Execute this file top-to-bottom in Snowflake (Snowsight or CLI)
--   2. Task starts SUSPENDED — resume at bottom of this file
--   3. Backfill section (§5) runs a one-time full-table MERGE
--
-- Key decisions:
--   • HOURLY_KWH = MAX - MIN of total_import_active_energy within hour (per device)
--     This is the pattern recommended in challenge.md — NOT a LAG diff, because
--     readings are ~60s apart and we want the cleanest per-hour consumption.
--   • IS_PEAK_HOUR uses MEA Thailand TOU: Mon-Fri 09:00-22:00 local (GMT+7)
--     Rate: Peak 4.50 ฿/kWh · Off-peak 2.60 ฿/kWh
--   • IS_ANOMALY = TRUE for PM-F3 (avg kW ≈ MAIN-MDB — wiring/config issue)
--     PM-F3 rows are retained in Silver but flagged to exclude from floor sums.
--   • QUALITY = BAD rows are excluded from MERGE (5 rows with ASSET = NULL).
-- ============================================================================

USE DATABASE  DE_CHALLENGE;
USE SCHEMA    SILVER;
USE WAREHOUSE CHALLENGE_WH;


-- ============================================================================
-- §1  DDL — SILVER.POWER_EVENTS
-- ============================================================================

CREATE OR REPLACE TABLE DE_CHALLENGE.SILVER.POWER_EVENTS (
    -- Keys & lineage
    EVENT_ID                VARCHAR         NOT NULL,   -- ASSET || '|' || EVENT_TS
    EVENT_TS                TIMESTAMP_NTZ   NOT NULL,   -- UTC (from Bronze)
    EVENT_TS_LOCAL          TIMESTAMP_NTZ   NOT NULL,   -- Asia/Bangkok (GMT+7)
    INGESTED_TS             TIMESTAMP_NTZ,

    -- UNS hierarchy
    ENTERPRISE              VARCHAR,
    SITE                    VARCHAR,
    AREA                    VARCHAR,
    WORK_CENTER             VARCHAR,
    ASSET                   VARCHAR         NOT NULL,   -- MAIN-MDB, PM-F1 … PM-F7

    -- Source metadata
    QUALITY                 VARCHAR,
    SCHEMA_VERSION          VARCHAR,
    SOURCE                  VARCHAR,
    CORRELATION_ID          VARCHAR,

    -- Location
    FLOOR_NUM               INTEGER,        -- 0 = MAIN-MDB, 1-7 = PM-F1–F7

    -- Instantaneous power readings
    ACTIVE_POWER_KW         FLOAT,          -- eq_active_power (kW)
    APPARENT_POWER_KVA      FLOAT,          -- eq_apparent_power (kVA)
    REACTIVE_POWER_KVAR     FLOAT,          -- eq_reactive_power (kVAr)
    POWER_FACTOR            FLOAT,          -- eq_power_factor (0–1)
    FREQUENCY_HZ            FLOAT,          -- frequency (Hz)
    PHASE_VOLTAGE_V         FLOAT,          -- eq_phase_v (V)
    LINE_VOLTAGE_V          FLOAT,          -- eq_phase_to_phase_voltage (V)
    CURRENT_A               FLOAT,          -- eq_current (A)

    -- Cumulative energy counters (raw — used to compute hourly diff in Gold)
    ENERGY_KWH_CUMUL        FLOAT,          -- total_import_active_energy
    ENERGY_KVARH_CUMUL      FLOAT,          -- total_import_reactive_energy
    ENERGY_KVAH_CUMUL       FLOAT,          -- total_apparent_energy

    -- Computed: time context
    IS_PEAK_HOUR            BOOLEAN,        -- Mon–Fri 09:00–22:00 local
    IS_WEEKEND              BOOLEAN,        -- Sat or Sun local
    HOUR_LOCAL              INTEGER,        -- 0–23 local hour
    DAY_OF_WEEK             INTEGER,        -- 1=Mon … 7=Sun (DAYOFWEEKISO)
    SHIFT_NAME              VARCHAR,        -- Day / Day OT / Night / Night OT

    -- Data quality flag
    IS_ANOMALY              BOOLEAN         -- TRUE for PM-F3 (wiring anomaly)
)
CLUSTER BY (ASSET, DATE_TRUNC('DAY', EVENT_TS_LOCAL))
COMMENT = 'Silver layer — Power meter events typed + enriched from BRONZE.RAW_EVENTS';


-- ============================================================================
-- §2  STREAM — CDC on BRONZE.RAW_EVENTS
-- ============================================================================

CREATE OR REPLACE STREAM DE_CHALLENGE.BRONZE.STREAM_POWER
    ON TABLE DE_CHALLENGE.BRONZE.RAW_EVENTS
    APPEND_ONLY = TRUE
    COMMENT = 'CDC stream — incremental power load (power_meter.raw.v1)';


-- ============================================================================
-- §3  STORED PROCEDURE — SP_LOAD_POWER
--     BRONZE.RAW_EVENTS (via STREAM_POWER) → SILVER.POWER_EVENTS
-- ============================================================================

CREATE OR REPLACE PROCEDURE DE_CHALLENGE.SILVER.SP_LOAD_POWER()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Incremental load: BRONZE stream → SILVER.POWER_EVENTS (MERGE)'
AS
$$
BEGIN
    BEGIN TRANSACTION;

    MERGE INTO DE_CHALLENGE.SILVER.POWER_EVENTS AS tgt
    USING (
        WITH src AS (
            SELECT
                s.EVENT_TS,
                s.ENTERPRISE,
                s.SITE,
                s.AREA,
                s.WORK_CENTER,
                s.ASSET,
                s.QUALITY,
                s.SCHEMA_VERSION,
                s.SOURCE,
                s.CORRELATION_ID,
                s.INGESTED_TS,
                PARSE_JSON(s.PAYLOAD)           AS p,
                -- deduplicate: keep latest ingestion per (ASSET, EVENT_TS)
                ROW_NUMBER() OVER (
                    PARTITION BY s.ASSET, s.EVENT_TS
                    ORDER BY s.INGESTED_TS DESC
                ) AS rn
            FROM DE_CHALLENGE.BRONZE.STREAM_POWER AS s
            WHERE s.SCHEMA_VERSION = 'power_meter.raw.v1'
              AND s.QUALITY != 'BAD'
              AND s.ASSET IS NOT NULL
        ),
        enriched AS (
            SELECT
                -- Surrogate key
                ASSET || '|' || EVENT_TS::VARCHAR   AS EVENT_ID,
                EVENT_TS,
                CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)
                                                    AS EVENT_TS_LOCAL,
                INGESTED_TS,

                -- UNS hierarchy
                ENTERPRISE,
                SITE,
                AREA,
                WORK_CENTER,
                ASSET,

                -- Metadata
                QUALITY,
                SCHEMA_VERSION,
                SOURCE,
                CORRELATION_ID,

                -- Location (floor field in payload is INTEGER or STRING)
                TRY_TO_NUMBER(p:floor::VARCHAR)     AS FLOOR_NUM,

                -- Instantaneous power
                p:eq_active_power::FLOAT            AS ACTIVE_POWER_KW,
                p:eq_apparent_power::FLOAT          AS APPARENT_POWER_KVA,
                p:eq_reactive_power::FLOAT          AS REACTIVE_POWER_KVAR,
                p:eq_power_factor::FLOAT            AS POWER_FACTOR,
                p:frequency::FLOAT                  AS FREQUENCY_HZ,
                p:eq_phase_v::FLOAT                 AS PHASE_VOLTAGE_V,
                p:eq_phase_to_phase_voltage::FLOAT  AS LINE_VOLTAGE_V,
                p:eq_current::FLOAT                 AS CURRENT_A,

                -- Cumulative counters
                p:total_import_active_energy::FLOAT AS ENERGY_KWH_CUMUL,
                p:total_import_reactive_energy::FLOAT AS ENERGY_KVARH_CUMUL,
                p:total_apparent_energy::FLOAT      AS ENERGY_KVAH_CUMUL,

                -- Time context (computed from local timestamp)
                CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)
                                                    AS _ts_local,
                HOUR(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                                                    AS _hour_local,
                DAYOFWEEKISO(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                                                    AS _dow,  -- 1=Mon … 7=Sun

                -- IS_PEAK_HOUR: Mon–Fri (1–5) AND 09:00–21:59 local
                CASE
                    WHEN DAYOFWEEKISO(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             BETWEEN 1 AND 5
                     AND HOUR(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             BETWEEN 9 AND 21
                    THEN TRUE ELSE FALSE
                END                                 AS IS_PEAK_HOUR,

                -- IS_WEEKEND
                CASE
                    WHEN DAYOFWEEKISO(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             IN (6, 7)
                    THEN TRUE ELSE FALSE
                END                                 AS IS_WEEKEND,

                HOUR(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                                                    AS HOUR_LOCAL,
                DAYOFWEEKISO(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                                                    AS DAY_OF_WEEK,

                -- SHIFT_NAME (same definitions as Production/Vibration)
                CASE
                    WHEN TIME(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             BETWEEN '00:45' AND '09:44' THEN 'Day'
                    WHEN TIME(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             BETWEEN '09:45' AND '12:44' THEN 'Day OT'
                    WHEN TIME(CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS))
                             BETWEEN '12:45' AND '21:44' THEN 'Night'
                    ELSE 'Night OT'
                END                                 AS SHIFT_NAME,

                -- Anomaly flag: PM-F3 ≈ MAIN-MDB (wiring issue confirmed)
                CASE WHEN ASSET = 'PM-F3' THEN TRUE ELSE FALSE END
                                                    AS IS_ANOMALY

            FROM src
            WHERE rn = 1
        )
        SELECT * FROM enriched
    ) AS src
    ON tgt.EVENT_ID = src.EVENT_ID

    WHEN MATCHED THEN UPDATE SET
        tgt.INGESTED_TS         = src.INGESTED_TS,
        tgt.ACTIVE_POWER_KW     = src.ACTIVE_POWER_KW,
        tgt.APPARENT_POWER_KVA  = src.APPARENT_POWER_KVA,
        tgt.REACTIVE_POWER_KVAR = src.REACTIVE_POWER_KVAR,
        tgt.POWER_FACTOR        = src.POWER_FACTOR,
        tgt.ENERGY_KWH_CUMUL    = src.ENERGY_KWH_CUMUL,
        tgt.IS_ANOMALY          = src.IS_ANOMALY

    WHEN NOT MATCHED THEN INSERT (
        EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
        ENTERPRISE, SITE, AREA, WORK_CENTER, ASSET,
        QUALITY, SCHEMA_VERSION, SOURCE, CORRELATION_ID,
        FLOOR_NUM,
        ACTIVE_POWER_KW, APPARENT_POWER_KVA, REACTIVE_POWER_KVAR,
        POWER_FACTOR, FREQUENCY_HZ, PHASE_VOLTAGE_V, LINE_VOLTAGE_V, CURRENT_A,
        ENERGY_KWH_CUMUL, ENERGY_KVARH_CUMUL, ENERGY_KVAH_CUMUL,
        IS_PEAK_HOUR, IS_WEEKEND, HOUR_LOCAL, DAY_OF_WEEK, SHIFT_NAME,
        IS_ANOMALY
    ) VALUES (
        src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
        src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.ASSET,
        src.QUALITY, src.SCHEMA_VERSION, src.SOURCE, src.CORRELATION_ID,
        src.FLOOR_NUM,
        src.ACTIVE_POWER_KW, src.APPARENT_POWER_KVA, src.REACTIVE_POWER_KVAR,
        src.POWER_FACTOR, src.FREQUENCY_HZ, src.PHASE_VOLTAGE_V,
        src.LINE_VOLTAGE_V, src.CURRENT_A,
        src.ENERGY_KWH_CUMUL, src.ENERGY_KVARH_CUMUL, src.ENERGY_KVAH_CUMUL,
        src.IS_PEAK_HOUR, src.IS_WEEKEND, src.HOUR_LOCAL, src.DAY_OF_WEEK,
        src.SHIFT_NAME, src.IS_ANOMALY
    );

    COMMIT;
    RETURN 'SP_LOAD_POWER completed: ' || SQLROWCOUNT || ' rows merged.';

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;


-- ============================================================================
-- §4  TASK — TASK_LOAD_POWER
-- ============================================================================

CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.TASK_LOAD_POWER
    WAREHOUSE   = CHALLENGE_WH
    SCHEDULE    = '15 MINUTE'
    COMMENT     = 'Runs SP_LOAD_POWER every 15 min when STREAM_POWER has new rows'
    WHEN        SYSTEM$STREAM_HAS_DATA('DE_CHALLENGE.BRONZE.STREAM_POWER')
AS
    CALL DE_CHALLENGE.SILVER.SP_LOAD_POWER();

-- Start suspended — resume when ready:
-- ALTER TASK DE_CHALLENGE.SILVER.TASK_LOAD_POWER RESUME;


-- ============================================================================
-- §5  BACKFILL — one-time full-table MERGE from RAW_EVENTS (not stream)
-- ============================================================================
-- Run this section manually once after deploying to load all historical data.
-- Uses the same transformation logic as SP_LOAD_POWER but reads RAW_EVENTS
-- directly (not the stream) so the stream offset is not consumed.
-- ============================================================================

MERGE INTO DE_CHALLENGE.SILVER.POWER_EVENTS AS tgt
USING (
    WITH src AS (
        SELECT
            EVENT_TS, ENTERPRISE, SITE, AREA, WORK_CENTER, ASSET,
            QUALITY, SCHEMA_VERSION, SOURCE, CORRELATION_ID, INGESTED_TS,
            PARSE_JSON(PAYLOAD) AS p,
            ROW_NUMBER() OVER (
                PARTITION BY ASSET, EVENT_TS
                ORDER BY INGESTED_TS DESC
            ) AS rn
        FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
        WHERE SCHEMA_VERSION = 'power_meter.raw.v1'
          AND QUALITY != 'BAD'
          AND ASSET IS NOT NULL
    )
    SELECT
        ASSET || '|' || EVENT_TS::VARCHAR           AS EVENT_ID,
        EVENT_TS,
        CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS) AS EVENT_TS_LOCAL,
        INGESTED_TS,
        ENTERPRISE, SITE, AREA, WORK_CENTER, ASSET,
        QUALITY, SCHEMA_VERSION, SOURCE, CORRELATION_ID,
        TRY_TO_NUMBER(p:floor::VARCHAR)             AS FLOOR_NUM,
        p:eq_active_power::FLOAT                    AS ACTIVE_POWER_KW,
        p:eq_apparent_power::FLOAT                  AS APPARENT_POWER_KVA,
        p:eq_reactive_power::FLOAT                  AS REACTIVE_POWER_KVAR,
        p:eq_power_factor::FLOAT                    AS POWER_FACTOR,
        p:frequency::FLOAT                          AS FREQUENCY_HZ,
        p:eq_phase_v::FLOAT                         AS PHASE_VOLTAGE_V,
        p:eq_phase_to_phase_voltage::FLOAT          AS LINE_VOLTAGE_V,
        p:eq_current::FLOAT                         AS CURRENT_A,
        p:total_import_active_energy::FLOAT         AS ENERGY_KWH_CUMUL,
        p:total_import_reactive_energy::FLOAT       AS ENERGY_KVARH_CUMUL,
        p:total_apparent_energy::FLOAT              AS ENERGY_KVAH_CUMUL,
        CASE
            WHEN DAYOFWEEKISO(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     BETWEEN 1 AND 5
             AND HOUR(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     BETWEEN 9 AND 21
            THEN TRUE ELSE FALSE
        END                                         AS IS_PEAK_HOUR,
        CASE
            WHEN DAYOFWEEKISO(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     IN (6, 7)
            THEN TRUE ELSE FALSE
        END                                         AS IS_WEEKEND,
        HOUR(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))   AS HOUR_LOCAL,
        DAYOFWEEKISO(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS)) AS DAY_OF_WEEK,
        CASE
            WHEN TIME(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     BETWEEN '00:45' AND '09:44' THEN 'Day'
            WHEN TIME(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     BETWEEN '09:45' AND '12:44' THEN 'Day OT'
            WHEN TIME(CONVERT_TIMEZONE('UTC','Asia/Bangkok',EVENT_TS))
                     BETWEEN '12:45' AND '21:44' THEN 'Night'
            ELSE 'Night OT'
        END                                         AS SHIFT_NAME,
        CASE WHEN ASSET = 'PM-F3' THEN TRUE ELSE FALSE END AS IS_ANOMALY
    FROM src
    WHERE rn = 1
) AS src
ON tgt.EVENT_ID = src.EVENT_ID
WHEN MATCHED THEN UPDATE SET
    tgt.INGESTED_TS         = src.INGESTED_TS,
    tgt.ACTIVE_POWER_KW     = src.ACTIVE_POWER_KW,
    tgt.ENERGY_KWH_CUMUL    = src.ENERGY_KWH_CUMUL,
    tgt.IS_ANOMALY          = src.IS_ANOMALY
WHEN NOT MATCHED THEN INSERT (
    EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
    ENTERPRISE, SITE, AREA, WORK_CENTER, ASSET,
    QUALITY, SCHEMA_VERSION, SOURCE, CORRELATION_ID,
    FLOOR_NUM,
    ACTIVE_POWER_KW, APPARENT_POWER_KVA, REACTIVE_POWER_KVAR,
    POWER_FACTOR, FREQUENCY_HZ, PHASE_VOLTAGE_V, LINE_VOLTAGE_V, CURRENT_A,
    ENERGY_KWH_CUMUL, ENERGY_KVARH_CUMUL, ENERGY_KVAH_CUMUL,
    IS_PEAK_HOUR, IS_WEEKEND, HOUR_LOCAL, DAY_OF_WEEK, SHIFT_NAME,
    IS_ANOMALY
) VALUES (
    src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
    src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.ASSET,
    src.QUALITY, src.SCHEMA_VERSION, src.SOURCE, src.CORRELATION_ID,
    src.FLOOR_NUM,
    src.ACTIVE_POWER_KW, src.APPARENT_POWER_KVA, src.REACTIVE_POWER_KVAR,
    src.POWER_FACTOR, src.FREQUENCY_HZ, src.PHASE_VOLTAGE_V,
    src.LINE_VOLTAGE_V, src.CURRENT_A,
    src.ENERGY_KWH_CUMUL, src.ENERGY_KVARH_CUMUL, src.ENERGY_KVAH_CUMUL,
    src.IS_PEAK_HOUR, src.IS_WEEKEND, src.HOUR_LOCAL, src.DAY_OF_WEEK,
    src.SHIFT_NAME, src.IS_ANOMALY
);


-- ============================================================================
-- §6  VERIFICATION QUERIES
-- ============================================================================

-- Row count per meter (expect ~37,764 each, 5 BAD excluded)
SELECT ASSET, COUNT(*) AS row_count, MIN(EVENT_TS_LOCAL) AS first_local,
       MAX(EVENT_TS_LOCAL) AS last_local, AVG(IS_ANOMALY::INTEGER) AS anomaly_rate
FROM DE_CHALLENGE.SILVER.POWER_EVENTS
GROUP BY ASSET ORDER BY ASSET;

-- Spot-check IS_PEAK_HOUR logic
SELECT HOUR_LOCAL, DAY_OF_WEEK, IS_PEAK_HOUR, IS_WEEKEND, COUNT(*) AS cnt
FROM DE_CHALLENGE.SILVER.POWER_EVENTS
GROUP BY 1,2,3,4 ORDER BY DAY_OF_WEEK, HOUR_LOCAL;

-- Confirm PM-F3 flagged as anomaly
SELECT ASSET, IS_ANOMALY, COUNT(*) AS cnt
FROM DE_CHALLENGE.SILVER.POWER_EVENTS
GROUP BY 1,2 ORDER BY 1;

-- Cumulative energy range per meter (sanity check for Gold)
SELECT ASSET, FLOOR_NUM,
       ROUND(MIN(ENERGY_KWH_CUMUL), 0) AS min_kwh_cumul,
       ROUND(MAX(ENERGY_KWH_CUMUL), 0) AS max_kwh_cumul,
       ROUND(MAX(ENERGY_KWH_CUMUL) - MIN(ENERGY_KWH_CUMUL), 0) AS total_kwh
FROM DE_CHALLENGE.SILVER.POWER_EVENTS
WHERE IS_ANOMALY = FALSE
GROUP BY ASSET, FLOOR_NUM ORDER BY FLOOR_NUM;
