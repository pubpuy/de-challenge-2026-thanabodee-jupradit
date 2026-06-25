-- ============================================================================
-- DE Challenge 2026 — Task 4 Capstone: Plant Health Dashboard
-- File   : 04_capstone_streamlit.sql
-- Option : A — Streamlit in Snowflake
--
-- Deployment:
--   Option 1 (recommended): snow streamlit deploy --connection de_challenge --replace --open
--   Option 2 (manual SQL):  Run §1 to create stage, then paste Python into Snowsight
--
-- Depends: GOLD.PRODUCTION_HOURLY + GOLD.VIBRATION_HOURLY (must be populated)
-- Answers: Q7 — Plant Health at a Glance (30-second overview)
-- ============================================================================

USE DATABASE  DE_CHALLENGE;
USE SCHEMA    GOLD;
USE WAREHOUSE CHALLENGE_WH;


-- ============================================================================
-- §1  CREATE STAGE (รองรับ Streamlit app files)
-- ============================================================================
-- Snow CLI จะสร้าง stage นี้อัตโนมัติถ้ายังไม่มี
-- รันด้วยมือถ้าต้องการ deploy ผ่าน SQL

CREATE STAGE IF NOT EXISTS DE_CHALLENGE.GOLD.STREAMLIT_STAGE
    COMMENT = 'Stage for Streamlit app files — Plant Health Dashboard';


-- ============================================================================
-- §2  CREATE STREAMLIT (สร้าง app object ใน Snowflake)
-- ============================================================================
-- Note: ถ้าใช้ Snow CLI (snow streamlit deploy) ไม่ต้องรัน statement นี้
--       CLI จะสร้าง STREAMLIT object ให้อัตโนมัติจาก snowflake.yml

CREATE OR REPLACE STREAMLIT DE_CHALLENGE.GOLD.PLANT_HEALTH_DASHBOARD
    ROOT_LOCATION = '@DE_CHALLENGE.GOLD.STREAMLIT_STAGE'
    MAIN_FILE     = 'plant_health.py'
    QUERY_WAREHOUSE = CHALLENGE_WH
    COMMENT       = 'Task 4 Capstone — Production + Vibration health dashboard (Q7)';


-- ============================================================================
-- §3  VERIFY + GET URL
-- ============================================================================

-- ดู Streamlit objects ที่มีใน schema
SHOW STREAMLITS IN SCHEMA DE_CHALLENGE.GOLD;

-- ดู URL ของ app (หลัง deploy ด้วย CLI ใช้คำสั่ง: snow streamlit get-url PLANT_HEALTH_DASHBOARD)
-- หรือ copy URL จาก Snowsight → Streamlit → เลือก app → Share button


-- ============================================================================
-- §4  VERIFICATION QUERIES  (ทดสอบ query ที่ app ใช้)
-- ============================================================================

-- Production summary (Section 1)
SELECT
    MACHINE_GROUP,
    GROUP_NUMBER,
    COUNT(DISTINCT ASSET)                                            AS machines,
    ROUND(AVG(UPTIME_PCT), 1)                                        AS avg_uptime_pct,
    SUM(PARTS_PRODUCED)                                              AS total_parts,
    ROUND(100.0 * SUM(PRODUCTIVE_READINGS)
                / NULLIF(SUM(TOTAL_READINGS - EXCLUDED_READINGS), 0), 1) AS productive_pct,
    ROUND(100.0 * SUM(PLANNED_STOP_READINGS)
                / NULLIF(SUM(TOTAL_READINGS), 0), 1)                 AS planned_stop_pct,
    ROUND(100.0 * SUM(UNPLANNED_DT_READINGS)
                / NULLIF(SUM(TOTAL_READINGS), 0), 1)                 AS unplanned_dt_pct,
    ROUND(100.0 * SUM(EXCLUDED_READINGS)
                / NULLIF(SUM(TOTAL_READINGS), 0), 1)                 AS excluded_pct
FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
GROUP BY MACHINE_GROUP, GROUP_NUMBER
ORDER BY GROUP_NUMBER;

-- Q4: Setup time top 10
SELECT
    ASSET,
    MACHINE_GROUP,
    ROUND(SUM(SETUP_MINUTES) / 60.0, 1)                              AS total_setup_hours,
    ROUND(100.0 * SUM(PLANNED_STOP_READINGS)
                / NULLIF(SUM(TOTAL_READINGS - EXCLUDED_READINGS), 0), 1) AS setup_pct
FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
GROUP BY ASSET, MACHINE_GROUP
ORDER BY total_setup_hours DESC
LIMIT 10;

-- Vibration summary (Section 2 — Q2)
SELECT
    ASSET,
    ROUND(AVG(AVG_RMS_VELOCITY), 2)   AS avg_rms,
    ROUND(MAX(MAX_RMS_VELOCITY), 2)   AS max_rms,
    SUM(READINGS_ZONE_A)              AS zone_a,
    SUM(READINGS_ZONE_B)              AS zone_b,
    SUM(READINGS_ZONE_C)              AS zone_c,
    SUM(READINGS_ZONE_D)              AS zone_d
FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
GROUP BY ASSET
ORDER BY ASSET;

-- Q5: motor_02 daily RMS trend
SELECT
    ASSET,
    DATE_TRUNC('DAY', HOUR_LOCAL)     AS day_local,
    ROUND(AVG(AVG_RMS_VELOCITY), 3)   AS daily_avg_rms,
    ROUND(AVG(ROLLING_7DAY_AVG_RMS), 3) AS rolling_7d_rms
FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
WHERE ASSET IN ('motor_02', 'motor_01')
GROUP BY ASSET, day_local
ORDER BY day_local;
