-- ============================================================================
-- DE Challenge 2026 — Task 1: Silver Schema (Production + Vibration)
-- Scope: Power domain deferred — see DESIGN.md
-- ============================================================================

USE DATABASE DE_CHALLENGE;
USE SCHEMA SILVER;
USE WAREHOUSE CHALLENGE_WH;

-- ---------------------------------------------------------------------------
-- SILVER.PRODUCTION_EVENTS
-- Source: BRONZE.RAW_EVENTS WHERE SCHEMA_VERSION = '0.1'
-- Unifies 3s (n3_*) and 60s (legacy_60) payload formats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.SILVER.PRODUCTION_EVENTS (
    -- Keys & lineage
    EVENT_ID                VARCHAR         NOT NULL,   -- ASSET || '|' || EVENT_TS || '|' || SCHEMA_VERSION
    EVENT_TS                TIMESTAMP_NTZ   NOT NULL,   -- UTC (from Bronze)
    EVENT_TS_LOCAL          TIMESTAMP_NTZ   NOT NULL,   -- Asia/Bangkok
    INGESTED_TS             TIMESTAMP_NTZ,

    -- UNS hierarchy
    ENTERPRISE              VARCHAR,
    SITE                    VARCHAR,
    AREA                    VARCHAR,
    WORK_CENTER             VARCHAR,
    WORK_CELL               VARCHAR,
    ASSET                   VARCHAR         NOT NULL,

    -- Source metadata
    SCHEMA_VERSION          VARCHAR         NOT NULL,
    SOURCE                  VARCHAR,
    QUALITY                 VARCHAR,
    PAYLOAD_FORMAT          VARCHAR         NOT NULL,   -- '3s' | '60s'
    SOURCE_PERIOD_SEC       NUMBER,                     -- 3 or 60

    -- Unified production fields (mapped from both payload formats)
    STATE_CODE              NUMBER,                     -- 800/801/803
    STATUS_CODE             NUMBER,                     -- e.g. 803105
    REASON_CODE             NUMBER,
    PARTS_DELTA             NUMBER,
    PARTS_COUNTER           NUMBER,
    COUNTER                 NUMBER,
    WO_NAME                 VARCHAR,
    WO_PART_NAME            VARCHAR,
    PLAN_ID                 VARCHAR,
    WO_CYCLE_TIME_SEC       FLOAT,

    -- Computed (Task 2) — populated by pipeline
    IS_PRODUCING            BOOLEAN,                    -- state=800 AND parts_delta>0 AND not ALWAYS_RUNNING
    DOWNTIME_CATEGORY       VARCHAR,                    -- PRODUCTIVE | PLANNED_STOP | UNPLANNED_DOWNTIME | EXCLUDED | UNKNOWN
    MACHINE_CATEGORY        VARCHAR,                    -- ACTIVE_PRODUCER | ALWAYS_RUNNING | IDLE_UNUSED

    -- Audit
    LOADED_AT               TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),

    PRIMARY KEY (EVENT_ID)
)
COMMENT = 'Typed production events — unified 3s/60s formats. Answers Q1 (via Gold).';

-- ---------------------------------------------------------------------------
-- SILVER.VIBRATION_EVENTS
-- Source: BRONZE.RAW_EVENTS WHERE SCHEMA_VERSION IN ('vibration.raw.v1','vibration.raw.v2')
-- Single table for v1 + v2 (same field names in full payloads)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.SILVER.VIBRATION_EVENTS (
    EVENT_ID                VARCHAR         NOT NULL,
    EVENT_TS                TIMESTAMP_NTZ   NOT NULL,
    EVENT_TS_LOCAL          TIMESTAMP_NTZ   NOT NULL,
    INGESTED_TS             TIMESTAMP_NTZ,

    ENTERPRISE              VARCHAR,
    SITE                    VARCHAR,
    AREA                    VARCHAR,
    WORK_CENTER             VARCHAR,
    WORK_CELL               VARCHAR,
    ASSET                   VARCHAR         NOT NULL,

    SCHEMA_VERSION          VARCHAR         NOT NULL,   -- vibration.raw.v1 | vibration.raw.v2
    SOURCE                  VARCHAR,
    QUALITY                 VARCHAR,
    IS_FULL_PAYLOAD         BOOLEAN         NOT NULL,   -- FALSE = sparse/BAD rows

    -- Core sensor fields
    ROTATIONAL_SPEED_RPM    FLOAT,
    ROTATIONAL_SPEED_HZ     FLOAT,
    TEMPERATURE_C           FLOAT,
    X_RMS_VELOCITY_MM_S     FLOAT,
    X_PEAK_ACCELERATION_G   FLOAT,
    X_CREST_FACTOR          FLOAT,
    X_KURTOSIS              FLOAT,
    Z_RMS_VELOCITY_MM_S     FLOAT,
    DEVICE_AVAILABLE        BOOLEAN,
    DEVICE_ERROR            BOOLEAN,

    -- Computed (Task 2)
    MACHINE_STATE           VARCHAR,                    -- RUNNING | STARTING_STOPPING | IDLE | OFFLINE
    ISO_ZONE                VARCHAR,                    -- A | B | C | D (ISO 10816 Class II, from x_rms_velocity)
    IS_QUARANTINED          BOOLEAN         DEFAULT FALSE,

    LOADED_AT               TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),

    PRIMARY KEY (EVENT_ID)
)
COMMENT = 'Typed vibration events — v1+v2 unified. Answers Q2 (via Silver/Gold).';

-- ---------------------------------------------------------------------------
-- SILVER.VIBRATION_QUARANTINE (optional — BAD / sparse rows)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE DE_CHALLENGE.SILVER.VIBRATION_QUARANTINE (
    EVENT_ID                VARCHAR         NOT NULL,
    EVENT_TS                TIMESTAMP_NTZ   NOT NULL,
    ASSET                   VARCHAR,
    SCHEMA_VERSION          VARCHAR,
    QUALITY                 VARCHAR,
    QUARANTINE_REASON       VARCHAR,                    -- QUALITY_BAD | SPARSE_PAYLOAD
    RAW_PAYLOAD             VARCHAR,
    LOADED_AT               TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),

    PRIMARY KEY (EVENT_ID)
)
COMMENT = 'Rejected vibration rows — QUALITY=BAD or sparse payload';
