-- Fix variant-to-boolean cast for device_available/device_error by casting through INT first
-- Co-authored with CoCo
-- ============================================================================
-- DE Challenge 2026 — Task 2: Silver Pipeline
-- File   : 02_silver_pipeline.sql
-- Depends: 02_silver_schema.sql (tables must exist first)
--
-- Strategy : Stream + Task + MERGE  (Incremental · Idempotent · Typed)
-- Domains  : Production + Vibration  (Power deferred — Phase 2)
--
-- Run order:
--   1. Execute this file top-to-bottom in Snowflake (Snowsight or CLI)
--   2. Tasks start SUSPENDED — resume them at the bottom of this file
--   3. Backfill section (§5) runs a one-time full-table MERGE
-- ============================================================================

USE DATABASE  DE_CHALLENGE;
USE SCHEMA    SILVER;
USE WAREHOUSE CHALLENGE_WH;


-- ============================================================================
-- §1  STREAMS (CDC on BRONZE.RAW_EVENTS)
-- ============================================================================
-- APPEND_ONLY = TRUE: RAW_EVENTS only ever gets INSERTs (COPY INTO),
--   so we skip full CDC overhead and process only new rows.
-- Each domain gets its own stream so their offsets advance independently.

CREATE OR REPLACE STREAM DE_CHALLENGE.BRONZE.STREAM_PRODUCTION
    ON TABLE DE_CHALLENGE.BRONZE.RAW_EVENTS
    APPEND_ONLY = TRUE
    COMMENT = 'CDC stream — incremental production load (SCHEMA_VERSION = 0.1)';

CREATE OR REPLACE STREAM DE_CHALLENGE.BRONZE.STREAM_VIBRATION
    ON TABLE DE_CHALLENGE.BRONZE.RAW_EVENTS
    APPEND_ONLY = TRUE
    COMMENT = 'CDC stream — incremental vibration load (v1 + v2)';


-- ============================================================================
-- §2  STORED PROCEDURE — Production
--     BRONZE.RAW_EVENTS  →  SILVER.PRODUCTION_EVENTS
-- ============================================================================
-- Design notes:
--   • Dual payload format (3s / 60s) unified via COALESCE on field aliases
--   • ROW_NUMBER dedup: (ASSET, EVENT_TS) — latest INGESTED_TS wins
--   • ALWAYS_RUNNING machines (FM48, FM51, FM44) flagged from Bronze findings
--   • 803105 = "No Order" → EXCLUDED (not counted as downtime per ISA-95)
--   • Transaction wraps the MERGE so stream offset advances atomically
-- ============================================================================

CREATE OR REPLACE PROCEDURE DE_CHALLENGE.SILVER.SP_LOAD_PRODUCTION()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Incremental load: BRONZE stream → SILVER.PRODUCTION_EVENTS (MERGE)'
AS
$$
BEGIN
    BEGIN TRANSACTION;

    MERGE INTO DE_CHALLENGE.SILVER.PRODUCTION_EVENTS AS tgt
    USING (
        WITH raw AS (
            SELECT
                -- Surrogate key: deterministic, human-readable
                ASSET
                    || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
                    || '|' || SCHEMA_VERSION                                      AS EVENT_ID,

                EVENT_TS,
                CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)                 AS EVENT_TS_LOCAL,
                INGESTED_TS,
                ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
                SCHEMA_VERSION, SOURCE, QUALITY,

                -- Parse once; reuse as VARIANT alias
                PARSE_JSON(PAYLOAD)                                                AS p,

                -- Format detection: field presence distinguishes 3s from 60s
                CASE
                    WHEN PARSE_JSON(PAYLOAD):n3_state_code IS NOT NULL        THEN '3s'
                    WHEN PARSE_JSON(PAYLOAD):machine_status_heartbeat IS NOT NULL THEN '60s'
                    ELSE 'unknown'
                END                                                                AS PAYLOAD_FORMAT,

                -- Dedup: multiple rows with same (ASSET, EVENT_TS) in Bronze
                -- (73K duplicate groups confirmed in Step-1 exploration)
                ROW_NUMBER() OVER (
                    PARTITION BY ASSET, EVENT_TS
                    ORDER BY INGESTED_TS DESC NULLS LAST
                )                                                                  AS rn

            FROM DE_CHALLENGE.BRONZE.STREAM_PRODUCTION
            WHERE SCHEMA_VERSION = '0.1'
        ),

        deduped AS (
            SELECT
                EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
                ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
                SCHEMA_VERSION, SOURCE, QUALITY, PAYLOAD_FORMAT,

                -- ── Unified state fields (3s field name / 60s field name) ──
                COALESCE(
                    p:n3_state_code::INT,
                    p:machine_status_heartbeat::INT
                )                                                                  AS STATE_CODE,

                p:n3_status_code::INT                                              AS STATUS_CODE,

                COALESCE(
                    p:n3_reason_code::INT,
                    p:reason_code_60::INT
                )                                                                  AS REASON_CODE,

                COALESCE(
                    p:wo_part_counter_delta::INT,
                    p:wo_part_counter_delta_60::INT
                )                                                                  AS PARTS_DELTA,

                p:wo_part_counter_no_reset::INT                                    AS PARTS_COUNTER,
                p:counter::INT                                                     AS COUNTER,
                p:wo_name::VARCHAR                                                 AS WO_NAME,
                p:wo_part_name::VARCHAR                                            AS WO_PART_NAME,
                p:plan_id::VARCHAR                                                 AS PLAN_ID,
                p:wo_cycle_time::FLOAT                                             AS WO_CYCLE_TIME_SEC,

                -- source_period as INT (3 or 60 seconds)
                CASE
                    WHEN p:source_period::VARCHAR ILIKE '%60%' THEN 60
                    ELSE 3
                END                                                                AS SOURCE_PERIOD_SEC,

                -- MACHINE_CATEGORY: ALWAYS_RUNNING hardcoded from Step-1 findings
                -- FM48 (Group2), FM51 (Group3), FM44 (Group2) report state=800
                -- but wo_part_counter_delta = 0 on every row
                CASE
                    WHEN ASSET IN ('FM48', 'FM51', 'FM44') THEN 'ALWAYS_RUNNING'
                    ELSE 'ACTIVE_PRODUCER'
                END                                                                AS MACHINE_CATEGORY

            FROM raw
            WHERE rn = 1
        ),

        enriched AS (
            SELECT *,
                -- DOWNTIME_CATEGORY per ISA-95 / isa95.md rules
                CASE
                    WHEN STATE_CODE = 800                                          THEN 'PRODUCTIVE'
                    WHEN STATE_CODE = 801                                          THEN 'PLANNED_STOP'
                    WHEN STATE_CODE = 803 AND STATUS_CODE = 803105                 THEN 'EXCLUDED'
                    WHEN STATE_CODE = 803                                          THEN 'UNPLANNED_DOWNTIME'
                    ELSE                                                               'UNKNOWN'
                END                                                                AS DOWNTIME_CATEGORY,

                -- IS_PRODUCING: machine actively making parts
                -- Excludes ALWAYS_RUNNING anomaly (counter never moves)
                CASE
                    WHEN STATE_CODE = 800
                     AND COALESCE(PARTS_DELTA, 0) > 0
                     AND MACHINE_CATEGORY <> 'ALWAYS_RUNNING'
                    THEN TRUE
                    ELSE FALSE
                END                                                                AS IS_PRODUCING

            FROM deduped
        )

        SELECT * FROM enriched

    ) src
    ON tgt.EVENT_ID = src.EVENT_ID

    -- Silver is append-only: identical EVENT_ID = already loaded, skip
    WHEN NOT MATCHED THEN
        INSERT (
            EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY, PAYLOAD_FORMAT, SOURCE_PERIOD_SEC,
            STATE_CODE, STATUS_CODE, REASON_CODE,
            PARTS_DELTA, PARTS_COUNTER, COUNTER,
            WO_NAME, WO_PART_NAME, PLAN_ID, WO_CYCLE_TIME_SEC,
            IS_PRODUCING, DOWNTIME_CATEGORY, MACHINE_CATEGORY
        )
        VALUES (
            src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
            src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.WORK_CELL, src.ASSET,
            src.SCHEMA_VERSION, src.SOURCE, src.QUALITY, src.PAYLOAD_FORMAT, src.SOURCE_PERIOD_SEC,
            src.STATE_CODE, src.STATUS_CODE, src.REASON_CODE,
            src.PARTS_DELTA, src.PARTS_COUNTER, src.COUNTER,
            src.WO_NAME, src.WO_PART_NAME, src.PLAN_ID, src.WO_CYCLE_TIME_SEC,
            src.IS_PRODUCING, src.DOWNTIME_CATEGORY, src.MACHINE_CATEGORY
        );

    COMMIT;
    RETURN 'OK: SP_LOAD_PRODUCTION completed';

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;


-- ============================================================================
-- §3  STORED PROCEDURE — Vibration
--     BRONZE.RAW_EVENTS  →  SILVER.VIBRATION_EVENTS  +  VIBRATION_QUARANTINE
-- ============================================================================
-- Design notes:
--   • v1 and v2 share identical field names (confirmed in Step-1; only semantics
--     / quality differ, not key names) → single code path, SCHEMA_VERSION tracked
--   • BAD quality OR sparse payload (≤5 keys) → QUARANTINE_EVENTS first
--   • Full-payload GOOD rows → VIBRATION_EVENTS with ISO_ZONE + MACHINE_STATE
--   • Both MERGEs wrapped in one transaction: stream consumed atomically,
--     no risk of STREAM_VIBRATION advancing between the two DML statements
--   • ROW_NUMBER dedup on (ASSET, EVENT_TS, SCHEMA_VERSION)
-- ============================================================================

CREATE OR REPLACE PROCEDURE DE_CHALLENGE.SILVER.SP_LOAD_VIBRATION()
    RETURNS VARCHAR
    LANGUAGE SQL
    COMMENT = 'Incremental load: BRONZE stream → SILVER.VIBRATION_EVENTS + QUARANTINE'
AS
$$
BEGIN
    BEGIN TRANSACTION;

    -- ── Step A: Quarantine — BAD quality or sparse payloads ──────────────────
    -- Sparse = ≤5 payload keys (v2 BAD rows confirmed to have only 4 fields)
    MERGE INTO DE_CHALLENGE.SILVER.VIBRATION_QUARANTINE AS tgt
    USING (
        SELECT
            ASSET
                || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
                || '|' || SCHEMA_VERSION                                           AS EVENT_ID,
            EVENT_TS,
            ASSET,
            SCHEMA_VERSION,
            QUALITY,
            CASE
                WHEN QUALITY = 'BAD'
                 AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) <= 5             THEN 'SPARSE_PAYLOAD'
                WHEN QUALITY = 'BAD'                                               THEN 'QUALITY_BAD'
                ELSE                                                                   'SPARSE_PAYLOAD'
            END                                                                    AS QUARANTINE_REASON,
            PAYLOAD                                                                AS RAW_PAYLOAD

        FROM DE_CHALLENGE.BRONZE.STREAM_VIBRATION
        WHERE SCHEMA_VERSION IN ('vibration.raw.v1', 'vibration.raw.v2')
          AND ASSET IS NOT NULL
          AND EVENT_TS IS NOT NULL
          AND (
                QUALITY = 'BAD'
             OR ARRAY_SIZE(OBJECT_KEYS(TRY_PARSE_JSON(PAYLOAD))) <= 5
          )
    ) src
    ON tgt.EVENT_ID = src.EVENT_ID
    WHEN NOT MATCHED THEN
        INSERT (EVENT_ID, EVENT_TS, ASSET, SCHEMA_VERSION, QUALITY, QUARANTINE_REASON, RAW_PAYLOAD)
        VALUES (src.EVENT_ID, src.EVENT_TS, src.ASSET, src.SCHEMA_VERSION,
                src.QUALITY, src.QUARANTINE_REASON, src.RAW_PAYLOAD);


    -- ── Step B: Full-payload GOOD rows → VIBRATION_EVENTS ────────────────────
    MERGE INTO DE_CHALLENGE.SILVER.VIBRATION_EVENTS AS tgt
    USING (
        WITH raw AS (
            SELECT
                ASSET
                    || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
                    || '|' || SCHEMA_VERSION                                       AS EVENT_ID,
                EVENT_TS,
                CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)                  AS EVENT_TS_LOCAL,
                INGESTED_TS,
                ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
                SCHEMA_VERSION, SOURCE, QUALITY,
                PARSE_JSON(PAYLOAD)                                                AS p,

                ROW_NUMBER() OVER (
                    PARTITION BY ASSET, EVENT_TS, SCHEMA_VERSION
                    ORDER BY INGESTED_TS DESC NULLS LAST
                )                                                                  AS rn

            FROM DE_CHALLENGE.BRONZE.STREAM_VIBRATION
            WHERE SCHEMA_VERSION IN ('vibration.raw.v1', 'vibration.raw.v2')
              AND QUALITY = 'GOOD'
              AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) > 5
        ),

        deduped AS (
            SELECT
                EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
                ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
                SCHEMA_VERSION, SOURCE, QUALITY,
                TRUE                                                                AS IS_FULL_PAYLOAD,

                -- Core sensor fields (v1 and v2 share the same key names)
                p:rotational_speed_rpm::FLOAT                                       AS ROTATIONAL_SPEED_RPM,
                p:rotational_speed_hz::FLOAT                                        AS ROTATIONAL_SPEED_HZ,
                p:temperature_c::FLOAT                                              AS TEMPERATURE_C,
                p:x_rms_velocity_mm_s::FLOAT                                        AS X_RMS_VELOCITY_MM_S,
                p:x_peak_acceleration_g::FLOAT                                      AS X_PEAK_ACCELERATION_G,
                p:x_crest_factor::FLOAT                                             AS X_CREST_FACTOR,
                p:x_kurtosis::FLOAT                                                 AS X_KURTOSIS,
                p:z_rms_velocity_mm_s::FLOAT                                        AS Z_RMS_VELOCITY_MM_S,
                TRY_CAST(p:device_available::STRING AS INT)::BOOLEAN                  AS DEVICE_AVAILABLE,
                TRY_CAST(p:device_error::STRING AS INT)::BOOLEAN                     AS DEVICE_ERROR

            FROM raw
            WHERE rn = 1
        ),

        enriched AS (
            SELECT *,
                -- MACHINE_STATE from RPM (data_dictionary.md §Domain 2)
                CASE
                    WHEN DEVICE_AVAILABLE = FALSE         THEN 'OFFLINE'
                    WHEN ROTATIONAL_SPEED_RPM >  100      THEN 'RUNNING'
                    WHEN ROTATIONAL_SPEED_RPM >  0        THEN 'STARTING_STOPPING'
                    ELSE                                       'IDLE'
                END                                                                 AS MACHINE_STATE,

                -- ISO_ZONE from x_rms_velocity (ISO 10816 Class II — isa95.md)
                -- A: 0–1.8  B: 1.8–4.5  C: 4.5–11.2  D: >11.2
                CASE
                    WHEN X_RMS_VELOCITY_MM_S IS NULL       THEN NULL
                    WHEN X_RMS_VELOCITY_MM_S <   1.8       THEN 'A'
                    WHEN X_RMS_VELOCITY_MM_S <   4.5       THEN 'B'
                    WHEN X_RMS_VELOCITY_MM_S <  11.2       THEN 'C'
                    ELSE                                        'D'
                END                                                                 AS ISO_ZONE,

                FALSE                                                               AS IS_QUARANTINED

            FROM deduped
        )

        SELECT * FROM enriched

    ) src
    ON tgt.EVENT_ID = src.EVENT_ID
    WHEN NOT MATCHED THEN
        INSERT (
            EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY, IS_FULL_PAYLOAD,
            ROTATIONAL_SPEED_RPM, ROTATIONAL_SPEED_HZ, TEMPERATURE_C,
            X_RMS_VELOCITY_MM_S, X_PEAK_ACCELERATION_G, X_CREST_FACTOR, X_KURTOSIS,
            Z_RMS_VELOCITY_MM_S, DEVICE_AVAILABLE, DEVICE_ERROR,
            MACHINE_STATE, ISO_ZONE, IS_QUARANTINED
        )
        VALUES (
            src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
            src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.WORK_CELL, src.ASSET,
            src.SCHEMA_VERSION, src.SOURCE, src.QUALITY, src.IS_FULL_PAYLOAD,
            src.ROTATIONAL_SPEED_RPM, src.ROTATIONAL_SPEED_HZ, src.TEMPERATURE_C,
            src.X_RMS_VELOCITY_MM_S, src.X_PEAK_ACCELERATION_G, src.X_CREST_FACTOR, src.X_KURTOSIS,
            src.Z_RMS_VELOCITY_MM_S, src.DEVICE_AVAILABLE, src.DEVICE_ERROR,
            src.MACHINE_STATE, src.ISO_ZONE, src.IS_QUARANTINED
        );

    COMMIT;
    RETURN 'OK: SP_LOAD_VIBRATION completed';

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;


-- ============================================================================
-- §4  TASKS (Scheduled execution — every 15 minutes)
-- ============================================================================
-- Tasks start in SUSPENDED state; resume at the end of this section.
-- Serverless Tasks are used (no explicit warehouse needed for compute scaling).

CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.TASK_LOAD_PRODUCTION
    WAREHOUSE   = CHALLENGE_WH
    SCHEDULE    = '15 MINUTE'
    COMMENT     = 'Runs SP_LOAD_PRODUCTION every 15 min when STREAM_PRODUCTION has new rows'
    WHEN        SYSTEM$STREAM_HAS_DATA('DE_CHALLENGE.BRONZE.STREAM_PRODUCTION')
AS
    CALL DE_CHALLENGE.SILVER.SP_LOAD_PRODUCTION();

CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.TASK_LOAD_VIBRATION
    WAREHOUSE   = CHALLENGE_WH
    SCHEDULE    = '15 MINUTE'
    COMMENT     = 'Runs SP_LOAD_VIBRATION every 15 min when STREAM_VIBRATION has new rows'
    WHEN        SYSTEM$STREAM_HAS_DATA('DE_CHALLENGE.BRONZE.STREAM_VIBRATION')
AS
    CALL DE_CHALLENGE.SILVER.SP_LOAD_VIBRATION();

-- Resume tasks (Tasks are SUSPENDED by default after CREATE)
ALTER TASK DE_CHALLENGE.SILVER.TASK_LOAD_PRODUCTION RESUME;
ALTER TASK DE_CHALLENGE.SILVER.TASK_LOAD_VIBRATION  RESUME;

-- Verify task status
SHOW TASKS IN SCHEMA DE_CHALLENGE.SILVER;


-- ============================================================================
-- §5  INITIAL BACKFILL  (run once — historical data pre-dates stream creation)
-- ============================================================================
-- Streams capture only rows INSERTed AFTER stream creation.
-- The ~27M rows already in RAW_EVENTS need a one-time MERGE from the base table.
-- Logic is identical to the procedures above, but source = RAW_EVENTS (not stream).
--
-- NOTE: This is a large query (~25M rows for production).
-- Expected runtime: 5–15 min on CHALLENGE_WH (XS/S warehouse).
-- Run in Snowsight or via Snowflake CLI.  Safe to re-run (MERGE is idempotent).

-- ── 5a: Backfill PRODUCTION_EVENTS ─────────────────────────────────────────
MERGE INTO DE_CHALLENGE.SILVER.PRODUCTION_EVENTS AS tgt
USING (
    WITH raw AS (
        SELECT
            ASSET
                || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
                || '|' || SCHEMA_VERSION                                           AS EVENT_ID,
            EVENT_TS,
            CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)                      AS EVENT_TS_LOCAL,
            INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY,
            PARSE_JSON(PAYLOAD)                                                     AS p,
            CASE
                WHEN PARSE_JSON(PAYLOAD):n3_state_code IS NOT NULL             THEN '3s'
                WHEN PARSE_JSON(PAYLOAD):machine_status_heartbeat IS NOT NULL  THEN '60s'
                ELSE 'unknown'
            END                                                                     AS PAYLOAD_FORMAT,
            ROW_NUMBER() OVER (
                PARTITION BY ASSET, EVENT_TS
                ORDER BY INGESTED_TS DESC NULLS LAST
            )                                                                       AS rn
        FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
        WHERE SCHEMA_VERSION = '0.1'
    ),
    deduped AS (
        SELECT
            EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY, PAYLOAD_FORMAT,
            COALESCE(p:n3_state_code::INT, p:machine_status_heartbeat::INT)         AS STATE_CODE,
            p:n3_status_code::INT                                                   AS STATUS_CODE,
            COALESCE(p:n3_reason_code::INT, p:reason_code_60::INT)                  AS REASON_CODE,
            COALESCE(
                p:wo_part_counter_delta::INT,
                p:wo_part_counter_delta_60::INT
            )                                                                       AS PARTS_DELTA,
            p:wo_part_counter_no_reset::INT                                         AS PARTS_COUNTER,
            p:counter::INT                                                          AS COUNTER,
            p:wo_name::VARCHAR                                                      AS WO_NAME,
            p:wo_part_name::VARCHAR                                                 AS WO_PART_NAME,
            p:plan_id::VARCHAR                                                      AS PLAN_ID,
            p:wo_cycle_time::FLOAT                                                  AS WO_CYCLE_TIME_SEC,
            CASE WHEN p:source_period::VARCHAR ILIKE '%60%' THEN 60 ELSE 3 END      AS SOURCE_PERIOD_SEC,
            CASE
                WHEN ASSET IN ('FM48', 'FM51', 'FM44') THEN 'ALWAYS_RUNNING'
                ELSE 'ACTIVE_PRODUCER'
            END                                                                     AS MACHINE_CATEGORY
        FROM raw
        WHERE rn = 1
    ),
    enriched AS (
        SELECT *,
            CASE
                WHEN STATE_CODE = 800                                               THEN 'PRODUCTIVE'
                WHEN STATE_CODE = 801                                               THEN 'PLANNED_STOP'
                WHEN STATE_CODE = 803 AND STATUS_CODE = 803105                      THEN 'EXCLUDED'
                WHEN STATE_CODE = 803                                               THEN 'UNPLANNED_DOWNTIME'
                ELSE                                                                    'UNKNOWN'
            END                                                                     AS DOWNTIME_CATEGORY,
            CASE
                WHEN STATE_CODE = 800
                 AND COALESCE(PARTS_DELTA, 0) > 0
                 AND MACHINE_CATEGORY <> 'ALWAYS_RUNNING'
                THEN TRUE
                ELSE FALSE
            END                                                                     AS IS_PRODUCING
        FROM deduped
    )
    SELECT * FROM enriched
) src
ON tgt.EVENT_ID = src.EVENT_ID
WHEN NOT MATCHED THEN
    INSERT (
        EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
        ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
        SCHEMA_VERSION, SOURCE, QUALITY, PAYLOAD_FORMAT, SOURCE_PERIOD_SEC,
        STATE_CODE, STATUS_CODE, REASON_CODE,
        PARTS_DELTA, PARTS_COUNTER, COUNTER,
        WO_NAME, WO_PART_NAME, PLAN_ID, WO_CYCLE_TIME_SEC,
        IS_PRODUCING, DOWNTIME_CATEGORY, MACHINE_CATEGORY
    )
    VALUES (
        src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
        src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.WORK_CELL, src.ASSET,
        src.SCHEMA_VERSION, src.SOURCE, src.QUALITY, src.PAYLOAD_FORMAT, src.SOURCE_PERIOD_SEC,
        src.STATE_CODE, src.STATUS_CODE, src.REASON_CODE,
        src.PARTS_DELTA, src.PARTS_COUNTER, src.COUNTER,
        src.WO_NAME, src.WO_PART_NAME, src.PLAN_ID, src.WO_CYCLE_TIME_SEC,
        src.IS_PRODUCING, src.DOWNTIME_CATEGORY, src.MACHINE_CATEGORY
    );


-- ── 5b: Backfill VIBRATION_QUARANTINE ──────────────────────────────────────
MERGE INTO DE_CHALLENGE.SILVER.VIBRATION_QUARANTINE AS tgt
USING (
    SELECT
        ASSET
            || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
            || '|' || SCHEMA_VERSION                                               AS EVENT_ID,
        EVENT_TS,
        ASSET,
        SCHEMA_VERSION,
        QUALITY,
        CASE
            WHEN QUALITY = 'BAD'
             AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) <= 5                 THEN 'SPARSE_PAYLOAD'
            WHEN QUALITY = 'BAD'                                                   THEN 'QUALITY_BAD'
            ELSE                                                                       'SPARSE_PAYLOAD'
        END                                                                        AS QUARANTINE_REASON,
        PAYLOAD                                                                    AS RAW_PAYLOAD
    FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
    WHERE SCHEMA_VERSION IN ('vibration.raw.v1', 'vibration.raw.v2')
      AND ASSET IS NOT NULL
      AND EVENT_TS IS NOT NULL
      AND (
            QUALITY = 'BAD'
         OR ARRAY_SIZE(OBJECT_KEYS(TRY_PARSE_JSON(PAYLOAD))) <= 5
      )
) src
ON tgt.EVENT_ID = src.EVENT_ID
WHEN NOT MATCHED THEN
    INSERT (EVENT_ID, EVENT_TS, ASSET, SCHEMA_VERSION, QUALITY, QUARANTINE_REASON, RAW_PAYLOAD)
    VALUES (src.EVENT_ID, src.EVENT_TS, src.ASSET, src.SCHEMA_VERSION,
            src.QUALITY, src.QUARANTINE_REASON, src.RAW_PAYLOAD);


-- ── 5c: Backfill VIBRATION_EVENTS ──────────────────────────────────────────
MERGE INTO DE_CHALLENGE.SILVER.VIBRATION_EVENTS AS tgt
USING (
    WITH raw AS (
        SELECT
            ASSET
                || '|' || TO_CHAR(EVENT_TS, 'YYYY-MM-DD HH24:MI:SS.FF6')
                || '|' || SCHEMA_VERSION                                           AS EVENT_ID,
            EVENT_TS,
            CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)                      AS EVENT_TS_LOCAL,
            INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY,
            PARSE_JSON(PAYLOAD)                                                     AS p,
            ROW_NUMBER() OVER (
                PARTITION BY ASSET, EVENT_TS, SCHEMA_VERSION
                ORDER BY INGESTED_TS DESC NULLS LAST
            )                                                                       AS rn
        FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
        WHERE SCHEMA_VERSION IN ('vibration.raw.v1', 'vibration.raw.v2')
          AND QUALITY = 'GOOD'
          AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) > 5
    ),
    deduped AS (
        SELECT
            EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
            ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
            SCHEMA_VERSION, SOURCE, QUALITY,
            TRUE                                                                    AS IS_FULL_PAYLOAD,
            p:rotational_speed_rpm::FLOAT                                           AS ROTATIONAL_SPEED_RPM,
            p:rotational_speed_hz::FLOAT                                            AS ROTATIONAL_SPEED_HZ,
            p:temperature_c::FLOAT                                                  AS TEMPERATURE_C,
            p:x_rms_velocity_mm_s::FLOAT                                            AS X_RMS_VELOCITY_MM_S,
            p:x_peak_acceleration_g::FLOAT                                          AS X_PEAK_ACCELERATION_G,
            p:x_crest_factor::FLOAT                                                 AS X_CREST_FACTOR,
            p:x_kurtosis::FLOAT                                                     AS X_KURTOSIS,
            p:z_rms_velocity_mm_s::FLOAT                                            AS Z_RMS_VELOCITY_MM_S,
            TRY_CAST(p:device_available::STRING AS INT)::BOOLEAN                      AS DEVICE_AVAILABLE,
            TRY_CAST(p:device_error::STRING AS INT)::BOOLEAN                         AS DEVICE_ERROR
        FROM raw
        WHERE rn = 1
    ),
    enriched AS (
        SELECT *,
            CASE
                WHEN DEVICE_AVAILABLE = FALSE         THEN 'OFFLINE'
                WHEN ROTATIONAL_SPEED_RPM >  100      THEN 'RUNNING'
                WHEN ROTATIONAL_SPEED_RPM >  0        THEN 'STARTING_STOPPING'
                ELSE                                      'IDLE'
            END                                                                     AS MACHINE_STATE,
            CASE
                WHEN X_RMS_VELOCITY_MM_S IS NULL       THEN NULL
                WHEN X_RMS_VELOCITY_MM_S <   1.8       THEN 'A'
                WHEN X_RMS_VELOCITY_MM_S <   4.5       THEN 'B'
                WHEN X_RMS_VELOCITY_MM_S <  11.2       THEN 'C'
                ELSE                                        'D'
            END                                                                     AS ISO_ZONE,
            FALSE                                                                   AS IS_QUARANTINED
        FROM deduped
    )
    SELECT * FROM enriched
) src
ON tgt.EVENT_ID = src.EVENT_ID
WHEN NOT MATCHED THEN
    INSERT (
        EVENT_ID, EVENT_TS, EVENT_TS_LOCAL, INGESTED_TS,
        ENTERPRISE, SITE, AREA, WORK_CENTER, WORK_CELL, ASSET,
        SCHEMA_VERSION, SOURCE, QUALITY, IS_FULL_PAYLOAD,
        ROTATIONAL_SPEED_RPM, ROTATIONAL_SPEED_HZ, TEMPERATURE_C,
        X_RMS_VELOCITY_MM_S, X_PEAK_ACCELERATION_G, X_CREST_FACTOR, X_KURTOSIS,
        Z_RMS_VELOCITY_MM_S, DEVICE_AVAILABLE, DEVICE_ERROR,
        MACHINE_STATE, ISO_ZONE, IS_QUARANTINED
    )
    VALUES (
        src.EVENT_ID, src.EVENT_TS, src.EVENT_TS_LOCAL, src.INGESTED_TS,
        src.ENTERPRISE, src.SITE, src.AREA, src.WORK_CENTER, src.WORK_CELL, src.ASSET,
        src.SCHEMA_VERSION, src.SOURCE, src.QUALITY, src.IS_FULL_PAYLOAD,
        src.ROTATIONAL_SPEED_RPM, src.ROTATIONAL_SPEED_HZ, src.TEMPERATURE_C,
        src.X_RMS_VELOCITY_MM_S, src.X_PEAK_ACCELERATION_G, src.X_CREST_FACTOR, src.X_KURTOSIS,
        src.Z_RMS_VELOCITY_MM_S, src.DEVICE_AVAILABLE, src.DEVICE_ERROR,
        src.MACHINE_STATE, src.ISO_ZONE, src.IS_QUARANTINED
    );


-- ============================================================================
-- §6  VERIFICATION QUERIES  (run after backfill to sanity-check)
-- ============================================================================

-- Row counts per Silver table
SELECT 'PRODUCTION_EVENTS'    AS tbl, COUNT(*) AS row_count FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS  UNION ALL
SELECT 'VIBRATION_EVENTS'     AS tbl, COUNT(*) AS row_count FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS   UNION ALL
SELECT 'VIBRATION_QUARANTINE' AS tbl, COUNT(*) AS row_count FROM DE_CHALLENGE.SILVER.VIBRATION_QUARANTINE;

-- Expected (after full backfill):
--   PRODUCTION_EVENTS    ≈ 25,562,378  (25,636,014 Bronze − 73,636 deduped)
--   VIBRATION_EVENTS     ≈ 1,154,447   (1,155,796 GOOD full-payload − deduped)
--   VIBRATION_QUARANTINE ≈     1,349   (1,337 v1 BAD + 12 v2 BAD)

-- ── Q1 preview: uptime % per group (normalize by machine count) ─────────────
SELECT
    WORK_CENTER                                                        AS machine_group,
    COUNT(DISTINCT ASSET)                                              AS machine_count,
    ROUND(
        100.0 * SUM(CASE WHEN IS_PRODUCING THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*), 0)
    , 1)                                                               AS producing_pct,
    ROUND(
        100.0 * SUM(CASE WHEN DOWNTIME_CATEGORY = 'PRODUCTIVE' THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*), 0)
    , 1)                                                               AS running_pct,
    ROUND(
        100.0 * SUM(CASE WHEN DOWNTIME_CATEGORY = 'UNPLANNED_DOWNTIME' THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*), 0)
    , 1)                                                               AS unplanned_pct,
    ROUND(
        100.0 * SUM(CASE WHEN DOWNTIME_CATEGORY = 'EXCLUDED' THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*), 0)
    , 1)                                                               AS no_order_pct
FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS
WHERE MACHINE_CATEGORY = 'ACTIVE_PRODUCER'
GROUP BY WORK_CENTER
ORDER BY WORK_CENTER;

-- ── Q2 preview: motor_02 ISO Zone distribution ──────────────────────────────
SELECT
    ASSET,
    ISO_ZONE,
    COUNT(*)                                                           AS readings,
    ROUND(AVG(X_RMS_VELOCITY_MM_S), 3)                                AS avg_rms_mm_s,
    ROUND(MAX(X_RMS_VELOCITY_MM_S), 3)                                AS max_rms_mm_s
FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS
WHERE ASSET = 'motor_02'
GROUP BY ASSET, ISO_ZONE
ORDER BY ISO_ZONE;

-- ── Quarantine breakdown ─────────────────────────────────────────────────────
SELECT ASSET, SCHEMA_VERSION, QUARANTINE_REASON, COUNT(*) AS cnt
FROM DE_CHALLENGE.SILVER.VIBRATION_QUARANTINE
GROUP BY 1, 2, 3
ORDER BY 1, 3;

-- ── Confirm dedup: no duplicate EVENT_ID in Silver ──────────────────────────
SELECT COUNT(*) AS dup_event_ids FROM (
    SELECT EVENT_ID, COUNT(*) AS c
    FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS
    GROUP BY EVENT_ID HAVING c > 1
);
-- Expected: 0

-- ── Confirm Tasks are STARTED ───────────────────────────────────────────────
SHOW TASKS IN SCHEMA DE_CHALLENGE.SILVER;
