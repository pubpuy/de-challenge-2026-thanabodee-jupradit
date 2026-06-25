-- ============================================================================
-- DE Challenge 2026 — Task 3: Gold Aggregation
-- File   : 03_gold_aggregation.sql
-- Depends: 02_silver_pipeline.sql (Silver tables must be populated)
--
-- Structure:
--   §1  Reference Tables  (static lookup data — run once)
--   §2  PRODUCTION_HOURLY (Gold aggregate — Part 2, coming next)
--   §3  VIBRATION_HOURLY  (Gold aggregate — Part 3, coming next)
-- ============================================================================

USE DATABASE  DE_CHALLENGE;
USE SCHEMA    GOLD;
USE WAREHOUSE CHALLENGE_WH;


-- ============================================================================
-- §1  REFERENCE TABLES  (static data — run once)           → ด้านล่าง
-- §2  PRODUCTION_HOURLY  (Gold aggregate — incremental)    → ด้านล่าง
-- §3  VIBRATION_HOURLY   (Gold aggregate — incremental)    → coming §3
-- ============================================================================


-- ============================================================================
-- §1  REFERENCE TABLES  (static data — INSERT OR REPLACE once)
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1a. SHIFT_DEFINITIONS
--     โรงงานมี 4 กะ (ไม่ standard) — เวลา local GMT+7
--     START_MIN / END_MIN = นาทีนับจากเที่ยงคืน (ใช้ JOIN กับ Gold ง่ายขึ้น)
--
--     กะ          | เวลา (local)      | duration
--     Day         | 00:45 – 09:45     | 9 ชม.
--     Day OT      | 09:45 – 12:45     | 3 ชม.
--     Night       | 12:45 – 21:45     | 9 ชม.
--     Night OT    | 21:45 – 00:45+1   | 3 ชม.  ← ข้ามเที่ยงคืน
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.SHIFT_DEFINITIONS (
    SHIFT_ID            NUMBER          NOT NULL,
    SHIFT_NAME          VARCHAR         NOT NULL,   -- Day | Day OT | Night | Night OT
    START_TIME_LOCAL    TIME            NOT NULL,   -- e.g. '00:45:00'
    END_TIME_LOCAL      TIME            NOT NULL,   -- e.g. '09:45:00'
    START_MIN           NUMBER          NOT NULL,   -- นาทีจากเที่ยงคืน (45)
    END_MIN             NUMBER          NOT NULL,   -- นาทีจากเที่ยงคืน (585)
    CROSSES_MIDNIGHT    BOOLEAN         NOT NULL,   -- TRUE = Night OT เท่านั้น
    DURATION_HOURS      FLOAT           NOT NULL,
    PRIMARY KEY (SHIFT_ID)
)
COMMENT = 'Factory shift schedule — local GMT+7. Non-standard 4-shift model.';

INSERT INTO DE_CHALLENGE.GOLD.SHIFT_DEFINITIONS
    (SHIFT_ID, SHIFT_NAME, START_TIME_LOCAL, END_TIME_LOCAL, START_MIN, END_MIN, CROSSES_MIDNIGHT, DURATION_HOURS)
VALUES
    (1, 'Day',      '00:45:00', '09:45:00',   45,  585, FALSE, 9.0),
    (2, 'Day OT',   '09:45:00', '12:45:00',  585,  765, FALSE, 3.0),
    (3, 'Night',    '12:45:00', '21:45:00',  765, 1305, FALSE, 9.0),
    (4, 'Night OT', '21:45:00', '00:45:00', 1305,   45, TRUE,  3.0);

-- Helper: ใช้ snippet นี้ใน Gold queries เพื่อหา shift จาก timestamp local
-- CASE
--     WHEN (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) >= 45
--      AND (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) <  585  THEN 'Day'
--     WHEN (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) >= 585
--      AND (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) <  765  THEN 'Day OT'
--     WHEN (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) >= 765
--      AND (EXTRACT(HOUR FROM ts_local)*60 + EXTRACT(MINUTE FROM ts_local)) < 1305  THEN 'Night'
--     ELSE 'Night OT'
-- END AS shift_name

SELECT * FROM DE_CHALLENGE.GOLD.SHIFT_DEFINITIONS ORDER BY SHIFT_ID;


-- ----------------------------------------------------------------------------
-- 1b. REASON_CODE_LOOKUP
--     Map STATUS_CODE → ชื่อที่อ่านง่าย + DOWNTIME_CATEGORY
--     ใช้สำหรับ Gold label และ Q1 top_downtime_reason
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.REASON_CODE_LOOKUP (
    STATUS_CODE         NUMBER,                     -- NULL = ไม่มีข้อมูล
    STATE_CODE          NUMBER,
    DOWNTIME_CATEGORY   VARCHAR         NOT NULL,   -- ตรงกับ Silver column
    REASON_NAME         VARCHAR         NOT NULL,   -- ชื่อแสดงผล
    REASON_NAME_TH      VARCHAR,                    -- ชื่อภาษาไทย (optional)
    IS_COUNTABLE_DT     BOOLEAN         NOT NULL,   -- นับเป็น downtime จริงไหม
    SORT_ORDER          NUMBER
)
COMMENT = 'Maps production status codes to human-readable downtime reasons';

INSERT INTO DE_CHALLENGE.GOLD.REASON_CODE_LOOKUP
    (STATUS_CODE, STATE_CODE, DOWNTIME_CATEGORY, REASON_NAME, REASON_NAME_TH, IS_COUNTABLE_DT, SORT_ORDER)
VALUES
    (800000, 800, 'PRODUCTIVE',          'Running',               'กำลังผลิต',              FALSE, 1),
    (801000, 801, 'PLANNED_STOP',        'Setup / Changeover',    'เปลี่ยนแม่พิมพ์/ตั้งค่า', TRUE,  2),
    (803105, 803, 'EXCLUDED',            'No Order Assigned',     'ไม่มี Work Order',        FALSE, 3),
    (803101, 803, 'UNPLANNED_DOWNTIME',  'Material Shortage',     'รอวัตถุดิบ',              TRUE,  4),
    (803112, 803, 'UNPLANNED_DOWNTIME',  'Mechanical Fault',      'เครื่องเสีย',             TRUE,  5),
    (803102, 803, 'UNPLANNED_DOWNTIME',  'Unknown Stop (102)',    'หยุดไม่ทราบสาเหตุ',       TRUE,  6),
    (803103, 803, 'UNPLANNED_DOWNTIME',  'Unknown Stop (103)',    'หยุดไม่ทราบสาเหตุ',       TRUE,  7),
    (803104, 803, 'UNPLANNED_DOWNTIME',  'Unknown Stop (104)',    'หยุดไม่ทราบสาเหตุ',       TRUE,  8),
    (803111, 803, 'UNPLANNED_DOWNTIME',  'Unknown Stop (111)',    'หยุดไม่ทราบสาเหตุ',       TRUE,  9),
    (NULL,   NULL, 'UNKNOWN',            'Offline / No Data',     'ไม่มีข้อมูล',             FALSE, 10);

SELECT * FROM DE_CHALLENGE.GOLD.REASON_CODE_LOOKUP ORDER BY SORT_ORDER;


-- ----------------------------------------------------------------------------
-- 1c. MACHINE_CONFIG
--     Master data ครบทุกเครื่อง (38 เครื่อง) จากข้อมูลจริง
--     ใช้ใน Gold สำหรับ join หา group + normalize per machine
--
--     สรุปจาก Silver exploration (23 มิ.ย. 2026):
--       Group1 (13): FM13,14,15,16,17,19,37,42,46,47,56,57,58  — ทุกตัว ACTIVE
--       Group2 (11): FM11,12,20,22,45,52,59,60,61 + FM44,FM48  — 2 ตัว ALWAYS_RUNNING
--       Group3 (6):  FM24,25,27,54,55 + FM51                   — 1 ตัว ALWAYS_RUNNING
--       Group4 (8):  FM21,28,29,30,31,32,50,53                 — ทุกตัว ACTIVE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.MACHINE_CONFIG (
    ASSET               VARCHAR         NOT NULL,
    MACHINE_GROUP       VARCHAR         NOT NULL,   -- Group1 | Group2 | Group3 | Group4
    GROUP_NUMBER        NUMBER          NOT NULL,   -- 1–4 (INT สำหรับ sort)
    MACHINE_CATEGORY    VARCHAR         NOT NULL,   -- ACTIVE_PRODUCER | ALWAYS_RUNNING
    IS_ALWAYS_RUNNING   BOOLEAN         NOT NULL,   -- shortcut flag
    NOTE                VARCHAR,
    PRIMARY KEY (ASSET)
)
COMMENT = 'Master config for all 38 forming machines — sourced from Silver exploration';

INSERT INTO DE_CHALLENGE.GOLD.MACHINE_CONFIG
    (ASSET, MACHINE_GROUP, GROUP_NUMBER, MACHINE_CATEGORY, IS_ALWAYS_RUNNING, NOTE)
VALUES
    -- ── Group 1 (13 เครื่อง — ทุกตัว ACTIVE) ───────────────────────────────
    ('FM13', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM14', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM15', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM16', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM17', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM19', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM37', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM42', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, 'High setup time (44.4% — Q4 candidate)'),
    ('FM46', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM47', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM56', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM57', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM58', 'Group1', 1, 'ACTIVE_PRODUCER', FALSE, NULL),

    -- ── Group 2 (11 เครื่อง — FM44, FM48 ALWAYS_RUNNING) ────────────────────
    ('FM11', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM12', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM20', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM22', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM44', 'Group2', 2, 'ALWAYS_RUNNING',  TRUE,  'state=800 ตลอด แต่ parts_delta=0 — ต้องตรวจ sensor'),
    ('FM45', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM48', 'Group2', 2, 'ALWAYS_RUNNING',  TRUE,  'state=800 ตลอด แต่ parts_delta=0 — ต้องตรวจ sensor'),
    ('FM52', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, 'Highest setup time (59.6% — Q4 top)'),
    ('FM59', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM60', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM61', 'Group2', 2, 'ACTIVE_PRODUCER', FALSE, NULL),

    -- ── Group 3 (6 เครื่อง — FM51 ALWAYS_RUNNING) ───────────────────────────
    ('FM24', 'Group3', 3, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM25', 'Group3', 3, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM27', 'Group3', 3, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM51', 'Group3', 3, 'ALWAYS_RUNNING',  TRUE,  'state=800 ตลอด แต่ parts_delta=0 — ต้องตรวจ sensor'),
    ('FM54', 'Group3', 3, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM55', 'Group3', 3, 'ACTIVE_PRODUCER', FALSE, NULL),

    -- ── Group 4 (8 เครื่อง — ทุกตัว ACTIVE) ────────────────────────────────
    ('FM21', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM28', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM29', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM30', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM31', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, 'High setup time (37.9% — Q4 candidate)'),
    ('FM32', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM50', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL),
    ('FM53', 'Group4', 4, 'ACTIVE_PRODUCER', FALSE, NULL);


-- ── Verify reference tables ────────────────────────────────────────────────

-- SHIFT_DEFINITIONS: ควรเห็น 4 แถว
SELECT SHIFT_ID, SHIFT_NAME, START_TIME_LOCAL, END_TIME_LOCAL, DURATION_HOURS
FROM DE_CHALLENGE.GOLD.SHIFT_DEFINITIONS
ORDER BY SHIFT_ID;

-- REASON_CODE_LOOKUP: ควรเห็น 10 แถว
SELECT STATUS_CODE, DOWNTIME_CATEGORY, REASON_NAME, IS_COUNTABLE_DT
FROM DE_CHALLENGE.GOLD.REASON_CODE_LOOKUP
ORDER BY SORT_ORDER;

-- MACHINE_CONFIG summary: ควรเห็น 4 groups, 38 เครื่องรวม
SELECT MACHINE_GROUP,
       COUNT(*)                                          AS total_machines,
       SUM(CASE WHEN IS_ALWAYS_RUNNING THEN 1 ELSE 0 END) AS always_running,
       COUNT(*) - SUM(CASE WHEN IS_ALWAYS_RUNNING THEN 1 ELSE 0 END) AS active_producers
FROM DE_CHALLENGE.GOLD.MACHINE_CONFIG
GROUP BY MACHINE_GROUP, GROUP_NUMBER
ORDER BY GROUP_NUMBER;
-- Expected:
--   Group1 | 13 | 0 | 13
--   Group2 | 11 | 2 |  9
--   Group3 |  6 | 1 |  5
--   Group4 |  8 | 0 |  8
--   Total  | 38 | 3 | 35


-- ============================================================================
-- §2  PRODUCTION_HOURLY
--     Source  : SILVER.PRODUCTION_EVENTS  (ACTIVE_PRODUCER เท่านั้น)
--     Grain   : 1 แถว ต่อ (ASSET × ชั่วโมง)
--     Answers : Q1 (Group3 uptime vs Group1) · Q4 (setup time per machine)
--
-- Design decisions:
--   • SETUP_MINUTES = SUM(SOURCE_PERIOD_SEC) WHERE state=801 / 60
--     → รองรับทั้ง 3s และ 60s format (ไม่ใช่แค่ count rows × 3)
--   • UPTIME_PCT = PRODUCTIVE / (TOTAL - EXCLUDED)
--     → ไม่นับ No Order (803105) เป็น downtime per ISA-95 decision
--   • MERGE key: (ASSET, HOUR_UTC) → idempotent, re-runs update current hour
--   • Full SP scan (~25M → ~27K Gold rows): fast enough for 1-hr schedule
-- ============================================================================

-- ── 2a: DDL — PRODUCTION_HOURLY ────────────────────────────────────────────
CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.PRODUCTION_HOURLY (
    -- Keys
    HOUR_UTC                TIMESTAMP_NTZ   NOT NULL,   -- truncated to hour (UTC)
    HOUR_LOCAL              TIMESTAMP_NTZ   NOT NULL,   -- local GMT+7
    ASSET                   VARCHAR         NOT NULL,

    -- Dimensions (denormalized from reference tables)
    MACHINE_GROUP           VARCHAR         NOT NULL,   -- Group1–4
    GROUP_NUMBER            NUMBER          NOT NULL,   -- 1–4 (for sort)
    SHIFT_NAME              VARCHAR,                    -- Day | Day OT | Night | Night OT

    -- Raw reading counts (flexible for downstream)
    TOTAL_READINGS          NUMBER          NOT NULL DEFAULT 0,
    PRODUCTIVE_READINGS     NUMBER          NOT NULL DEFAULT 0,   -- state=800
    PLANNED_STOP_READINGS   NUMBER          NOT NULL DEFAULT 0,   -- state=801
    UNPLANNED_DT_READINGS   NUMBER          NOT NULL DEFAULT 0,   -- state=803 excl. 105
    EXCLUDED_READINGS       NUMBER          NOT NULL DEFAULT 0,   -- state=803105
    UNKNOWN_READINGS        NUMBER          NOT NULL DEFAULT 0,   -- state=NULL/other

    -- Computed KPIs
    AVAILABLE_READINGS      NUMBER,                     -- TOTAL - EXCLUDED
    UPTIME_PCT              FLOAT,                      -- PRODUCTIVE / AVAILABLE × 100
    PARTS_PRODUCED          NUMBER          NOT NULL DEFAULT 0,   -- SUM(PARTS_DELTA)
    SETUP_MINUTES           FLOAT,                      -- SUM(SOURCE_PERIOD_SEC) state=801 / 60
    AVG_CYCLE_TIME_SEC      FLOAT,                      -- AVG(WO_CYCLE_TIME_SEC) when producing

    -- Top non-productive reason (for Q1 dashboard)
    TOP_STOP_CATEGORY       VARCHAR,                    -- UNPLANNED_DOWNTIME | PLANNED_STOP | EXCLUDED

    LOADED_AT               TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (ASSET, HOUR_UTC)
)
COMMENT = 'Hourly production KPIs per machine — answers Q1 (uptime) and Q4 (setup time)';


-- ── 2b: Stored Procedure — SP_LOAD_PRODUCTION_HOURLY ──────────────────────
CREATE OR REPLACE PROCEDURE DE_CHALLENGE.SILVER.SP_LOAD_PRODUCTION_HOURLY()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Full MERGE: SILVER.PRODUCTION_EVENTS → GOLD.PRODUCTION_HOURLY'
AS
$$
BEGIN
    MERGE INTO DE_CHALLENGE.GOLD.PRODUCTION_HOURLY AS tgt
    USING (
        WITH hourly_base AS (
            SELECT
                DATE_TRUNC('HOUR', EVENT_TS)                                        AS HOUR_UTC,
                DATE_TRUNC('HOUR', EVENT_TS_LOCAL)                                  AS HOUR_LOCAL,
                ASSET,
                DOWNTIME_CATEGORY,
                STATUS_CODE,
                COALESCE(PARTS_DELTA, 0)                                            AS PARTS_DELTA,
                COALESCE(SOURCE_PERIOD_SEC, 3)                                      AS PERIOD_SEC,
                WO_CYCLE_TIME_SEC,

                -- Shift classification (local GMT+7 — isa95.md)
                CASE
                    WHEN (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) >= 45
                     AND (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) <  585              THEN 'Day'
                    WHEN (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) >= 585
                     AND (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) <  765              THEN 'Day OT'
                    WHEN (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) >= 765
                     AND (EXTRACT(HOUR   FROM EVENT_TS_LOCAL) * 60
                        + EXTRACT(MINUTE FROM EVENT_TS_LOCAL)) < 1305              THEN 'Night'
                    ELSE                                                                'Night OT'
                END                                                                 AS SHIFT_NAME

            FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS
            WHERE MACHINE_CATEGORY = 'ACTIVE_PRODUCER'
        ),

        hourly_agg AS (
            SELECT
                HOUR_UTC,
                HOUR_LOCAL,
                ASSET,
                SHIFT_NAME,

                COUNT(*)                                                             AS TOTAL_READINGS,
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'PRODUCTIVE'         THEN 1 ELSE 0 END) AS PRODUCTIVE_READINGS,
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'PLANNED_STOP'       THEN 1 ELSE 0 END) AS PLANNED_STOP_READINGS,
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'UNPLANNED_DOWNTIME' THEN 1 ELSE 0 END) AS UNPLANNED_DT_READINGS,
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'EXCLUDED'           THEN 1 ELSE 0 END) AS EXCLUDED_READINGS,
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'UNKNOWN'            THEN 1 ELSE 0 END) AS UNKNOWN_READINGS,

                SUM(PARTS_DELTA)                                                     AS PARTS_PRODUCED,

                -- Setup minutes: SUM of actual period (3s or 60s) ÷ 60
                SUM(CASE WHEN DOWNTIME_CATEGORY = 'PLANNED_STOP'
                         THEN PERIOD_SEC ELSE 0 END) / 60.0                          AS SETUP_MINUTES,

                AVG(CASE WHEN DOWNTIME_CATEGORY = 'PRODUCTIVE'
                         THEN WO_CYCLE_TIME_SEC END)                                 AS AVG_CYCLE_TIME_SEC

            FROM hourly_base
            GROUP BY HOUR_UTC, HOUR_LOCAL, ASSET, SHIFT_NAME
        ),

        enriched AS (
            SELECT
                ha.HOUR_UTC,
                ha.HOUR_LOCAL,
                ha.ASSET,
                mc.MACHINE_GROUP,
                mc.GROUP_NUMBER,
                ha.SHIFT_NAME,
                ha.TOTAL_READINGS,
                ha.PRODUCTIVE_READINGS,
                ha.PLANNED_STOP_READINGS,
                ha.UNPLANNED_DT_READINGS,
                ha.EXCLUDED_READINGS,
                ha.UNKNOWN_READINGS,

                -- Available = ไม่นับ EXCLUDED (No Order ไม่ใช่ downtime จริง)
                (ha.TOTAL_READINGS - ha.EXCLUDED_READINGS)                           AS AVAILABLE_READINGS,

                -- Uptime = productive / available (NULL ถ้าทั้งชั่วโมงเป็น No Order)
                CASE
                    WHEN (ha.TOTAL_READINGS - ha.EXCLUDED_READINGS) = 0 THEN NULL
                    ELSE ROUND(
                        100.0 * ha.PRODUCTIVE_READINGS
                              / (ha.TOTAL_READINGS - ha.EXCLUDED_READINGS)
                    , 1)
                END                                                                   AS UPTIME_PCT,

                ha.PARTS_PRODUCED,
                ha.SETUP_MINUTES,
                ha.AVG_CYCLE_TIME_SEC,

                -- TOP_STOP_CATEGORY: reason นอกจาก PRODUCTIVE ที่มีมากสุด
                CASE
                    WHEN ha.UNPLANNED_DT_READINGS >= ha.PLANNED_STOP_READINGS
                     AND ha.UNPLANNED_DT_READINGS >= ha.EXCLUDED_READINGS             THEN 'UNPLANNED_DOWNTIME'
                    WHEN ha.PLANNED_STOP_READINGS >= ha.EXCLUDED_READINGS             THEN 'PLANNED_STOP'
                    ELSE                                                                  'EXCLUDED'
                END                                                                   AS TOP_STOP_CATEGORY

            FROM hourly_agg ha
            JOIN DE_CHALLENGE.GOLD.MACHINE_CONFIG mc
              ON ha.ASSET = mc.ASSET
        )

        SELECT * FROM enriched

    ) src
    ON  tgt.ASSET    = src.ASSET
    AND tgt.HOUR_UTC = src.HOUR_UTC

    -- UPDATE: re-aggregate เมื่อชั่วโมงปัจจุบันมีข้อมูลเพิ่มเข้ามา
    WHEN MATCHED THEN UPDATE SET
        tgt.HOUR_LOCAL              = src.HOUR_LOCAL,
        tgt.SHIFT_NAME              = src.SHIFT_NAME,
        tgt.TOTAL_READINGS          = src.TOTAL_READINGS,
        tgt.PRODUCTIVE_READINGS     = src.PRODUCTIVE_READINGS,
        tgt.PLANNED_STOP_READINGS   = src.PLANNED_STOP_READINGS,
        tgt.UNPLANNED_DT_READINGS   = src.UNPLANNED_DT_READINGS,
        tgt.EXCLUDED_READINGS       = src.EXCLUDED_READINGS,
        tgt.UNKNOWN_READINGS        = src.UNKNOWN_READINGS,
        tgt.AVAILABLE_READINGS      = src.AVAILABLE_READINGS,
        tgt.UPTIME_PCT              = src.UPTIME_PCT,
        tgt.PARTS_PRODUCED          = src.PARTS_PRODUCED,
        tgt.SETUP_MINUTES           = src.SETUP_MINUTES,
        tgt.AVG_CYCLE_TIME_SEC      = src.AVG_CYCLE_TIME_SEC,
        tgt.TOP_STOP_CATEGORY       = src.TOP_STOP_CATEGORY,
        tgt.LOADED_AT               = CURRENT_TIMESTAMP()

    WHEN NOT MATCHED THEN INSERT (
        HOUR_UTC, HOUR_LOCAL, ASSET,
        MACHINE_GROUP, GROUP_NUMBER, SHIFT_NAME,
        TOTAL_READINGS, PRODUCTIVE_READINGS, PLANNED_STOP_READINGS,
        UNPLANNED_DT_READINGS, EXCLUDED_READINGS, UNKNOWN_READINGS,
        AVAILABLE_READINGS, UPTIME_PCT,
        PARTS_PRODUCED, SETUP_MINUTES, AVG_CYCLE_TIME_SEC,
        TOP_STOP_CATEGORY
    ) VALUES (
        src.HOUR_UTC, src.HOUR_LOCAL, src.ASSET,
        src.MACHINE_GROUP, src.GROUP_NUMBER, src.SHIFT_NAME,
        src.TOTAL_READINGS, src.PRODUCTIVE_READINGS, src.PLANNED_STOP_READINGS,
        src.UNPLANNED_DT_READINGS, src.EXCLUDED_READINGS, src.UNKNOWN_READINGS,
        src.AVAILABLE_READINGS, src.UPTIME_PCT,
        src.PARTS_PRODUCED, src.SETUP_MINUTES, src.AVG_CYCLE_TIME_SEC,
        src.TOP_STOP_CATEGORY
    );

    RETURN 'OK: SP_LOAD_PRODUCTION_HOURLY completed';

EXCEPTION
    WHEN OTHER THEN RAISE;
END;
$$;


-- ── 2c: Task — รันทุก 1 ชั่วโมง ────────────────────────────────────────────
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.TASK_LOAD_PRODUCTION_HOURLY
    WAREHOUSE = CHALLENGE_WH
    SCHEDULE  = '60 MINUTE'
    COMMENT   = 'Hourly Gold aggregation — Production'
AS
    CALL DE_CHALLENGE.SILVER.SP_LOAD_PRODUCTION_HOURLY();

ALTER TASK DE_CHALLENGE.SILVER.TASK_LOAD_PRODUCTION_HOURLY RESUME;


-- ── 2d: Initial Load + Verification ────────────────────────────────────────
-- รัน SP ครั้งแรกเพื่อ load ข้อมูลทั้งหมดจาก Silver
CALL DE_CHALLENGE.SILVER.SP_LOAD_PRODUCTION_HOURLY();

-- Row count (คาดหวัง: ~27K แถว = 38 เครื่อง × 720 ชม.)
SELECT COUNT(*) AS gold_rows FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY;

-- ── Q1: Uptime % per group (normalize per machine) ─────────────────────────
SELECT
    MACHINE_GROUP,
    COUNT(DISTINCT ASSET)                            AS machines,
    ROUND(AVG(UPTIME_PCT), 1)                        AS avg_uptime_pct,
    ROUND(SUM(PARTS_PRODUCED) / COUNT(DISTINCT ASSET), 0) AS parts_per_machine,
    -- Top stop reason across group
    CASE
        WHEN SUM(UNPLANNED_DT_READINGS) >= SUM(PLANNED_STOP_READINGS)
         AND SUM(UNPLANNED_DT_READINGS) >= SUM(EXCLUDED_READINGS)        THEN 'Unplanned Downtime'
        WHEN SUM(PLANNED_STOP_READINGS) >= SUM(EXCLUDED_READINGS)        THEN 'Setup / Changeover'
        ELSE                                                                  'No Order (Excluded)'
    END                                                                  AS top_stop_reason
FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
GROUP BY MACHINE_GROUP, GROUP_NUMBER
ORDER BY GROUP_NUMBER;

-- ── Q4: Setup time per machine (top 10) ─────────────────────────────────────
SELECT
    ASSET,
    MACHINE_GROUP,
    ROUND(SUM(SETUP_MINUTES) / 60.0, 1)             AS total_setup_hours,
    ROUND(100.0 * SUM(PLANNED_STOP_READINGS)
               / NULLIF(SUM(TOTAL_READINGS - EXCLUDED_READINGS), 0), 1) AS setup_pct
FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
GROUP BY ASSET, MACHINE_GROUP
ORDER BY total_setup_hours DESC
LIMIT 10;


-- ============================================================================
-- §3  VIBRATION_HOURLY
--     Source  : SILVER.VIBRATION_EVENTS  (IS_QUARANTINED = FALSE เท่านั้น)
--     Grain   : 1 แถว ต่อ (ASSET × ชั่วโมง)
--     Answers : Q2 (motor_02 ISO Zone) · Q5 (RMS trend 7 วัน)
--
-- Design decisions:
--   • DOMINANT_ISO_ZONE = zone ที่มี readings มากสุดในชั่วโมงนั้น
--     → ใช้ ROW_NUMBER() OVER (PARTITION BY ASSET, HOUR ORDER BY COUNT DESC)
--     → Snowflake ไม่มี MODE() aggregate จึงต้องทำผ่าน CTE
--   • ROLLING_7DAY_AVG_RMS = window function 168 ชม. ย้อนหลัง
--     → คำนวณด้วย UPDATE แยกหลัง MERGE เพื่อหลีกเลี่ยง circular dependency
--   • รวม v1 + v2 ในตารางเดียว (SCHEMA_VERSION tracked ต่อแถว Silver)
-- ============================================================================

-- ── 3a: DDL — VIBRATION_HOURLY ─────────────────────────────────────────────
CREATE OR REPLACE TABLE DE_CHALLENGE.GOLD.VIBRATION_HOURLY (
    -- Keys
    HOUR_UTC                TIMESTAMP_NTZ   NOT NULL,
    HOUR_LOCAL              TIMESTAMP_NTZ   NOT NULL,
    ASSET                   VARCHAR         NOT NULL,   -- motor_01–04

    -- Volume
    READING_COUNT           NUMBER          NOT NULL DEFAULT 0,

    -- RMS Velocity (core ISO metric)
    AVG_RMS_VELOCITY        FLOAT,                      -- mm/s  → ISO Zone
    MAX_RMS_VELOCITY        FLOAT,                      -- mm/s  → worst case in hour
    DOMINANT_ISO_ZONE       VARCHAR,                    -- A|B|C|D (zone มี readings มากสุด)

    -- Zone reading breakdown (สำหรับ dashboard / drill-down)
    READINGS_ZONE_A         NUMBER          NOT NULL DEFAULT 0,
    READINGS_ZONE_B         NUMBER          NOT NULL DEFAULT 0,
    READINGS_ZONE_C         NUMBER          NOT NULL DEFAULT 0,
    READINGS_ZONE_D         NUMBER          NOT NULL DEFAULT 0,

    -- Motor state
    AVG_RPM                 FLOAT,
    DOMINANT_MACHINE_STATE  VARCHAR,                    -- RUNNING | IDLE | STARTING_STOPPING | OFFLINE
    READINGS_RUNNING        NUMBER          NOT NULL DEFAULT 0,
    READINGS_IDLE           NUMBER          NOT NULL DEFAULT 0,
    READINGS_OFFLINE        NUMBER          NOT NULL DEFAULT 0,

    -- Bearing health indicators
    AVG_TEMPERATURE_C       FLOAT,
    AVG_CREST_FACTOR        FLOAT,                      -- >6 = probable bearing damage
    MAX_CREST_FACTOR        FLOAT,
    AVG_KURTOSIS            FLOAT,                      -- >5 = impulsive vibration

    -- 7-day rolling trend (for Q5) — computed by UPDATE after MERGE
    ROLLING_7DAY_AVG_RMS    FLOAT,

    LOADED_AT               TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (ASSET, HOUR_UTC)
)
COMMENT = 'Hourly vibration KPIs per motor — answers Q2 (ISO Zone) and Q5 (7-day trend)';


-- ── 3b: Stored Procedure — SP_LOAD_VIBRATION_HOURLY ───────────────────────
CREATE OR REPLACE PROCEDURE DE_CHALLENGE.SILVER.SP_LOAD_VIBRATION_HOURLY()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Full MERGE: SILVER.VIBRATION_EVENTS → GOLD.VIBRATION_HOURLY + rolling avg UPDATE'
AS
$$
BEGIN
    -- ── Step 1: MERGE hourly aggregates ─────────────────────────────────────
    MERGE INTO DE_CHALLENGE.GOLD.VIBRATION_HOURLY AS tgt
    USING (
        WITH hourly_agg AS (
            SELECT
                DATE_TRUNC('HOUR', EVENT_TS)            AS HOUR_UTC,
                DATE_TRUNC('HOUR', EVENT_TS_LOCAL)      AS HOUR_LOCAL,
                ASSET,

                COUNT(*)                                 AS READING_COUNT,

                -- RMS velocity
                AVG(X_RMS_VELOCITY_MM_S)                AS AVG_RMS_VELOCITY,
                MAX(X_RMS_VELOCITY_MM_S)                AS MAX_RMS_VELOCITY,

                -- Zone counts
                SUM(CASE WHEN ISO_ZONE = 'A' THEN 1 ELSE 0 END) AS READINGS_ZONE_A,
                SUM(CASE WHEN ISO_ZONE = 'B' THEN 1 ELSE 0 END) AS READINGS_ZONE_B,
                SUM(CASE WHEN ISO_ZONE = 'C' THEN 1 ELSE 0 END) AS READINGS_ZONE_C,
                SUM(CASE WHEN ISO_ZONE = 'D' THEN 1 ELSE 0 END) AS READINGS_ZONE_D,

                -- Motor state
                AVG(ROTATIONAL_SPEED_RPM)               AS AVG_RPM,
                SUM(CASE WHEN MACHINE_STATE = 'RUNNING'           THEN 1 ELSE 0 END) AS READINGS_RUNNING,
                SUM(CASE WHEN MACHINE_STATE = 'IDLE'              THEN 1 ELSE 0 END) AS READINGS_IDLE,
                SUM(CASE WHEN MACHINE_STATE = 'OFFLINE'           THEN 1 ELSE 0 END) AS READINGS_OFFLINE,

                -- Bearing health
                AVG(TEMPERATURE_C)                      AS AVG_TEMPERATURE_C,
                AVG(X_CREST_FACTOR)                     AS AVG_CREST_FACTOR,
                MAX(X_CREST_FACTOR)                     AS MAX_CREST_FACTOR,
                AVG(X_KURTOSIS)                         AS AVG_KURTOSIS

            FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS
            WHERE IS_QUARANTINED = FALSE
              AND X_RMS_VELOCITY_MM_S IS NOT NULL
            GROUP BY HOUR_UTC, HOUR_LOCAL, ASSET
        ),

        -- DOMINANT_ISO_ZONE: zone ที่มี readings มากสุดในชั่วโมงนั้น
        -- Snowflake ไม่มี MODE() → ใช้ ROW_NUMBER() บน sub-aggregation
        zone_ranked AS (
            SELECT
                DATE_TRUNC('HOUR', EVENT_TS)            AS HOUR_UTC,
                ASSET,
                ISO_ZONE,
                COUNT(*)                                 AS zone_cnt,
                ROW_NUMBER() OVER (
                    PARTITION BY DATE_TRUNC('HOUR', EVENT_TS), ASSET
                    ORDER BY COUNT(*) DESC NULLS LAST
                )                                        AS rn
            FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS
            WHERE IS_QUARANTINED = FALSE
              AND ISO_ZONE IS NOT NULL
            GROUP BY 1, 2, 3
        ),

        dominant_zone AS (
            SELECT HOUR_UTC, ASSET, ISO_ZONE AS DOMINANT_ISO_ZONE
            FROM zone_ranked
            WHERE rn = 1
        ),

        -- DOMINANT_MACHINE_STATE: state ที่มี readings มากสุด
        state_ranked AS (
            SELECT
                DATE_TRUNC('HOUR', EVENT_TS)            AS HOUR_UTC,
                ASSET,
                MACHINE_STATE,
                COUNT(*)                                 AS state_cnt,
                ROW_NUMBER() OVER (
                    PARTITION BY DATE_TRUNC('HOUR', EVENT_TS), ASSET
                    ORDER BY COUNT(*) DESC NULLS LAST
                )                                        AS rn
            FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS
            WHERE IS_QUARANTINED = FALSE
              AND MACHINE_STATE IS NOT NULL
            GROUP BY 1, 2, 3
        ),

        dominant_state AS (
            SELECT HOUR_UTC, ASSET, MACHINE_STATE AS DOMINANT_MACHINE_STATE
            FROM state_ranked
            WHERE rn = 1
        )

        SELECT
            ha.HOUR_UTC,
            ha.HOUR_LOCAL,
            ha.ASSET,
            ha.READING_COUNT,
            ha.AVG_RMS_VELOCITY,
            ha.MAX_RMS_VELOCITY,
            dz.DOMINANT_ISO_ZONE,
            ha.READINGS_ZONE_A,
            ha.READINGS_ZONE_B,
            ha.READINGS_ZONE_C,
            ha.READINGS_ZONE_D,
            ha.AVG_RPM,
            ds.DOMINANT_MACHINE_STATE,
            ha.READINGS_RUNNING,
            ha.READINGS_IDLE,
            ha.READINGS_OFFLINE,
            ha.AVG_TEMPERATURE_C,
            ha.AVG_CREST_FACTOR,
            ha.MAX_CREST_FACTOR,
            ha.AVG_KURTOSIS

        FROM hourly_agg ha
        LEFT JOIN dominant_zone  dz ON ha.HOUR_UTC = dz.HOUR_UTC AND ha.ASSET = dz.ASSET
        LEFT JOIN dominant_state ds ON ha.HOUR_UTC = ds.HOUR_UTC AND ha.ASSET = ds.ASSET

    ) src
    ON  tgt.ASSET    = src.ASSET
    AND tgt.HOUR_UTC = src.HOUR_UTC

    WHEN MATCHED THEN UPDATE SET
        tgt.HOUR_LOCAL              = src.HOUR_LOCAL,
        tgt.READING_COUNT           = src.READING_COUNT,
        tgt.AVG_RMS_VELOCITY        = src.AVG_RMS_VELOCITY,
        tgt.MAX_RMS_VELOCITY        = src.MAX_RMS_VELOCITY,
        tgt.DOMINANT_ISO_ZONE       = src.DOMINANT_ISO_ZONE,
        tgt.READINGS_ZONE_A         = src.READINGS_ZONE_A,
        tgt.READINGS_ZONE_B         = src.READINGS_ZONE_B,
        tgt.READINGS_ZONE_C         = src.READINGS_ZONE_C,
        tgt.READINGS_ZONE_D         = src.READINGS_ZONE_D,
        tgt.AVG_RPM                 = src.AVG_RPM,
        tgt.DOMINANT_MACHINE_STATE  = src.DOMINANT_MACHINE_STATE,
        tgt.READINGS_RUNNING        = src.READINGS_RUNNING,
        tgt.READINGS_IDLE           = src.READINGS_IDLE,
        tgt.READINGS_OFFLINE        = src.READINGS_OFFLINE,
        tgt.AVG_TEMPERATURE_C       = src.AVG_TEMPERATURE_C,
        tgt.AVG_CREST_FACTOR        = src.AVG_CREST_FACTOR,
        tgt.MAX_CREST_FACTOR        = src.MAX_CREST_FACTOR,
        tgt.AVG_KURTOSIS            = src.AVG_KURTOSIS,
        tgt.LOADED_AT               = CURRENT_TIMESTAMP()

    WHEN NOT MATCHED THEN INSERT (
        HOUR_UTC, HOUR_LOCAL, ASSET, READING_COUNT,
        AVG_RMS_VELOCITY, MAX_RMS_VELOCITY, DOMINANT_ISO_ZONE,
        READINGS_ZONE_A, READINGS_ZONE_B, READINGS_ZONE_C, READINGS_ZONE_D,
        AVG_RPM, DOMINANT_MACHINE_STATE,
        READINGS_RUNNING, READINGS_IDLE, READINGS_OFFLINE,
        AVG_TEMPERATURE_C, AVG_CREST_FACTOR, MAX_CREST_FACTOR, AVG_KURTOSIS
    ) VALUES (
        src.HOUR_UTC, src.HOUR_LOCAL, src.ASSET, src.READING_COUNT,
        src.AVG_RMS_VELOCITY, src.MAX_RMS_VELOCITY, src.DOMINANT_ISO_ZONE,
        src.READINGS_ZONE_A, src.READINGS_ZONE_B, src.READINGS_ZONE_C, src.READINGS_ZONE_D,
        src.AVG_RPM, src.DOMINANT_MACHINE_STATE,
        src.READINGS_RUNNING, src.READINGS_IDLE, src.READINGS_OFFLINE,
        src.AVG_TEMPERATURE_C, src.AVG_CREST_FACTOR, src.MAX_CREST_FACTOR, src.AVG_KURTOSIS
    );

    -- ── Step 2: UPDATE ROLLING_7DAY_AVG_RMS ─────────────────────────────────
    -- คำนวณ window function หลัง MERGE เพื่อหลีกเลี่ยง circular dependency
    -- 168 rows = 7 วัน × 24 ชั่วโมง (rolling ต่อ motor)
    UPDATE DE_CHALLENGE.GOLD.VIBRATION_HOURLY tgt
    SET ROLLING_7DAY_AVG_RMS = sub.rolling_avg
    FROM (
        SELECT
            ASSET,
            HOUR_UTC,
            ROUND(
                AVG(AVG_RMS_VELOCITY) OVER (
                    PARTITION BY ASSET
                    ORDER BY HOUR_UTC
                    ROWS BETWEEN 167 PRECEDING AND CURRENT ROW
                )
            , 3) AS rolling_avg
        FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
    ) sub
    WHERE tgt.ASSET    = sub.ASSET
      AND tgt.HOUR_UTC = sub.HOUR_UTC;

    RETURN 'OK: SP_LOAD_VIBRATION_HOURLY completed';

EXCEPTION
    WHEN OTHER THEN RAISE;
END;
$$;


-- ── 3c: Task — รันทุก 1 ชั่วโมง ────────────────────────────────────────────
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.TASK_LOAD_VIBRATION_HOURLY
    WAREHOUSE = CHALLENGE_WH
    SCHEDULE  = '60 MINUTE'
    COMMENT   = 'Hourly Gold aggregation — Vibration'
AS
    CALL DE_CHALLENGE.SILVER.SP_LOAD_VIBRATION_HOURLY();

ALTER TASK DE_CHALLENGE.SILVER.TASK_LOAD_VIBRATION_HOURLY RESUME;


-- ── 3d: Initial Load + Verification ────────────────────────────────────────
CALL DE_CHALLENGE.SILVER.SP_LOAD_VIBRATION_HOURLY();

-- Row count (คาดหวัง: ~4 motors × ~700 ชม. ≈ ~2,800 แถว)
SELECT COUNT(*) AS gold_rows FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY;

-- ── Q2: motor_02 — ISO Zone ปัจจุบัน ────────────────────────────────────────
SELECT
    ASSET,
    DOMINANT_ISO_ZONE                               AS current_zone,
    ROUND(AVG_RMS_VELOCITY, 2)                      AS avg_rms_mm_s,
    ROUND(MAX_RMS_VELOCITY, 2)                      AS max_rms_mm_s,
    DOMINANT_MACHINE_STATE                          AS motor_state
FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
WHERE ASSET = 'motor_02'
ORDER BY HOUR_UTC DESC
LIMIT 5;

-- ── Q5: motor_02 — 7-day RMS trend (weekly avg) ──────────────────────────────
SELECT
    ASSET,
    DATE_TRUNC('WEEK', HOUR_LOCAL)                  AS week_start_local,
    ROUND(AVG(AVG_RMS_VELOCITY), 3)                 AS weekly_avg_rms,
    ROUND(AVG(ROLLING_7DAY_AVG_RMS), 3)             AS rolling_7day_avg,
    MAX(DOMINANT_ISO_ZONE)                          AS worst_zone_in_week,
    SUM(READINGS_ZONE_D)                            AS zone_d_readings
FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
WHERE ASSET = 'motor_02'
GROUP BY ASSET, week_start_local
ORDER BY week_start_local;

-- ── All motors — ISO Zone summary ────────────────────────────────────────────
SELECT
    ASSET,
    DOMINANT_ISO_ZONE                               AS dominant_zone,
    ROUND(AVG(AVG_RMS_VELOCITY), 2)                 AS overall_avg_rms,
    ROUND(MAX(MAX_RMS_VELOCITY), 2)                 AS peak_rms,
    SUM(READINGS_ZONE_D)                            AS zone_d_hours
FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
GROUP BY ASSET, DOMINANT_ISO_ZONE
ORDER BY ASSET, DOMINANT_ISO_ZONE;
