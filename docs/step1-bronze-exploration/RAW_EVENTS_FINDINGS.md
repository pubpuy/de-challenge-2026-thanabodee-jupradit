# Step 1 — สำรวจ Bronze Layer (`RAW_EVENTS`)

> บันทึกผลการสำรวจข้อมูลดิบก่อนออกแบบ Silver/Gold  
> สำรวจเมื่อ: 22 มิ.ย. 2026  
> ตาราง: `DE_CHALLENGE.BRONZE.RAW_EVENTS`  
> วิธีเช็ค: Snowflake CLI (`snow sql -q "..."`) ผ่าน `scripts/activate-snow.ps1`

---

## สรุปสั้น (TL;DR)

| หัวข้อ | สรุป |
|--------|------|
| ปริมาณรวม | ~27.1 ล้านแถว, 4 `SCHEMA_VERSION` |
| Finding สำคัญที่สุด | **`PAYLOAD` เป็น `VARCHAR` (JSON string)** — ต้อง `PARSE_JSON(PAYLOAD)` ก่อน extract field |
| Production | มี **2 payload formats** (3s + 60s) ภายใต้ `SCHEMA_VERSION = '0.1'` |
| Vibration | `QUALITY = BAD` มีเฉพาะ domain นี้; v1→v2 มี gap ~7.5 ชม. |
| Power | `PM-F3` อ่านค่าใกล้ `MAIN-MDB` ผิดปกติ (wiring issue) |
| Q1 preview | Group3 running ratio ต่ำกว่า Group1 ชัดเจน (26% vs 50%) |
| Q2 preview | `motor_02` avg RMS สูงสุด (~10.7 mm/s) |

---

## โครงสร้างตาราง

`DESCRIBE TABLE DE_CHALLENGE.BRONZE.RAW_EVENTS` → **14 columns**

| Column | Type | หมายเหตุ |
|--------|------|----------|
| EVENT_TS | TIMESTAMP_NTZ | **UTC** — ต้อง +7 ชม. สำหรับเวลาไทย |
| ENTERPRISE | VARCHAR | compomax |
| SITE | VARCHAR | compomax_site |
| AREA | VARCHAR | Forming, air_chiller, control_room |
| WORK_CENTER | VARCHAR | Group1–4, chiller, electrical |
| WORK_CELL | VARCHAR | มัก NULL (production) |
| ASSET | VARCHAR | FM22, motor_01, MAIN-MDB ฯลฯ |
| ASSET_PATH | VARCHAR | Full MQTT topic path |
| NAMESPACE | VARCHAR | Partial path |
| QUALITY | VARCHAR | GOOD / BAD |
| **PAYLOAD** | **VARCHAR** | **JSON string — ไม่ใช่ VARIANT** |
| INGESTED_TS | TIMESTAMP_NTZ | UTC |
| SCHEMA_VERSION | VARCHAR | ระบุ domain + schema |
| SOURCE | VARCHAR | aws_iot_core |
| CORRELATION_ID | VARCHAR | มักว่าง |

### ⚠️ การอ่าน PAYLOAD

```sql
-- ❌ ได้ NULL ทั้งหมด
SELECT PAYLOAD:n3_state_code FROM DE_CHALLENGE.BRONZE.RAW_EVENTS;

-- ✅ ถูกต้อง
SELECT PARSE_JSON(PAYLOAD):n3_state_code::INT FROM DE_CHALLENGE.BRONZE.RAW_EVENTS;
```

---

## จำนวนแถวตาม SCHEMA_VERSION

```sql
SELECT SCHEMA_VERSION, COUNT(*) AS cnt
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
GROUP BY 1 ORDER BY cnt DESC;
```

| SCHEMA_VERSION | จำนวนแถว | Domain |
|----------------|----------|--------|
| `0.1` | 25,636,014 | Production (Forming machines) |
| `vibration.raw.v2` | 582,034 | Vibration (หลัง firmware update) |
| `vibration.raw.v1` | 573,762 | Vibration (ก่อน firmware update) |
| `power_meter.raw.v1` | 302,117 | Power meters |
| **รวม** | **~27,093,927** | |

---

## Domain 1: Production (`SCHEMA_VERSION = '0.1'`)

### ข้อมูลทั่วไป

| รายการ | ค่า |
|--------|-----|
| Assets | 38 เครื่อง (FMxx) |
| ช่วงเวลา (UTC) | 2026-05-26 07:23:34 → 2026-06-20 09:21:16 |
| ความถี่หลัก | ทุก 3 วินาที |

### เครื่องจักรต่อ Work Center

| WORK_CENTER | จำนวนเครื่อง |
|-------------|-------------|
| Group1 | 13 |
| Group2 | 11 |
| Group3 | 6 |
| Group4 | 8 |
| **รวม** | **38** |

> หมายเหตุ: จำนวนต่อ group ไม่ตรง `data_dictionary.md` (10/10/8/10) แต่รวม 38 ถูกต้อง — ใช้ค่าจากข้อมูลจริง

### สอง Payload Formats ใน domain เดียวกัน

Production ใช้ `SCHEMA_VERSION = '0.1'` ทั้งคู่ แต่ payload structure ต่างกัน:

#### Format A — 3 วินาที (~24.4M แถว)

Key หลัก: `n3_state_code`, `n3_status_code`, `n3_reason_code`, `wo_part_counter_delta`, `counter`, `wo_name`, `plan_id` ฯลฯ

ตัวอย่าง (FM22):

```json
{
  "connected": "true",
  "counter": 116506,
  "n3_reason_code": 105,
  "n3_state_code": 803,
  "n3_status_code": 803105,
  "wo_part_counter_delta": 0,
  "source_period": "3s"
}
```

#### Format B — 60 วินาที (~1.2M แถว, ~32K/เครื่อง)

Key หลัก: `machine_status_heartbeat`, `reason_code_60`, `wo_part_counter_delta_60`, `shift_window`, `wo_downtime_60` ฯลฯ

ตัวอย่าง (FM13):

```json
{
  "connected": "true",
  "machine_status_heartbeat": 803,
  "reason_code_60": 105,
  "wo_part_counter_delta_60": 0,
  "source_period": "60s",
  "shift_window": "26/05/2026_NightOT"
}
```

**Silver ต้อง unify mapping:**

| ความหมาย | Format 3s | Format 60s |
|----------|-----------|------------|
| State code | `n3_state_code` | `machine_status_heartbeat` |
| Status/reason | `n3_status_code` / `n3_reason_code` | `reason_code_60` |
| Parts delta | `wo_part_counter_delta` | `wo_part_counter_delta_60` |

### State Codes (จากข้อมูลจริง)

| n3_state_code | n3_status_code | ความหมาย | จำนวนแถว | Treatment ที่แนะนำ |
|---------------|----------------|----------|----------|-------------------|
| 803 | 803105 | **No Order Assigned** | 9,320,833 | EXCLUDED จาก downtime |
| 800 | 800000 | **Running** | 8,522,136 | PRODUCTIVE |
| 801 | 801000 | **Setup / Changeover** | 4,064,292 | PLANNED_STOP |
| 803 | 803101 | Material Shortage | 1,538,160 | UNPLANNED_DOWNTIME |
| 803 | 803112 | Mechanical Fault | 726,359 | UNPLANNED_DOWNTIME |
| 803 | 803102–104, 803111 | Unknown (TBD) | ~243K | UNPLANNED_DOWNTIME |

> **803105 (No Order)** ครอง "downtime" ส่วนใหญ่ — ถ้านับรวม uptime จะต่ำเกินจริง

### ALWAYS_RUNNING Machines

เครื่องที่ IT/scenario ระบุ: **FM48, FM51, FM44**

| เครื่อง | Group | Running (state=800) | Producing (delta>0) | max_delta |
|---------|-------|--------------------|--------------------|-----------|
| FM48 | Group2 | 642,861 | 0 | 0 |
| FM51 | Group3 | 496,709 | 0 | 0 |
| FM44 | Group2 | 640,379 | 0 | 0 |

- รายงาน `state=800` (Running) ตลอด แต่ `wo_part_counter_delta = 0` ทุกแถว
- ต้อง tag เป็น `ALWAYS_RUNNING` ใน `MACHINE_CONFIG`
- **ไม่ควรนับเป็น throughput / OEE จริง**

### Preview Q1 — Running ratio ต่อ Group

(เฉพาะแถว Format 3s ที่มี `n3_state_code`)

| Group | Running rows | Total rows | Running % |
|-------|-------------|------------|-----------|
| Group1 | 4,206,319 | 8,353,407 | **50.3%** |
| Group2 | 2,489,359 | 7,065,763 | 35.2% |
| Group3 | 990,448 | 3,856,428 | **25.7%** |
| Group4 | 836,010 | 5,139,184 | 16.3% |

Group3 มีเครื่องน้อยกว่า (6 vs 13) และ running ratio ต่ำ — ต้อง **normalize per machine** ใน Gold ไม่ใช่ดู raw count อย่างเดียว

---

## Domain 2: Vibration (`vibration.raw.v1` / `vibration.raw.v2`)

### ข้อมูลทั่วไป

| รายการ | v1 | v2 |
|--------|----|----|
| Assets | motor_01–04 | motor_01–04 |
| ช่วงเวลา (UTC) | 2026-05-22 09:48:50 → 2026-06-11 04:58:06 | 2026-06-11 12:26:05 → 2026-06-20 09:20:15 |
| จำนวนแถว | 573,762 | 582,034 |
| Full payload rows | 573,762 | 582,022 |
| Sparse payload rows | 0 | 12 (QUALITY=BAD) |

### Schema Evolution v1 → v2

- เปลี่ยนวันที่ **11 มิ.ย. 2026** (firmware update ตาม scenario)
- มี **gap ~7.5 ชม.** ระหว่าง v1 สิ้นสุด (04:58 UTC) กับ v2 เริ่ม (12:26 UTC)
- เปรียบเทียบ `OBJECT_KEYS(PARSE_JSON(PAYLOAD))` ของ full payload: **ชื่อ field เหมือนกัน** (53 fields)
- Evolution อาจอยู่ที่ semantics, quality, หรือ sparse payloads — ไม่ใช่แค่ rename field

### Key fields สำหรับ Silver

| Field | ใช้ทำอะไร |
|-------|-----------|
| `x_rms_velocity_mm_s` | ISO Zone assessment (Q2) |
| `rotational_speed_rpm` | MACHINE_STATE (RUNNING/IDLE) |
| `x_crest_factor`, `x_kurtosis` | Bearing condition |
| `device_available`, `device_error` | Sensor health |

### QUALITY = BAD (เฉพาะ Vibration)

| SCHEMA_VERSION | GOOD | BAD |
|----------------|------|-----|
| vibration.raw.v1 | 572,425 | **1,337** |
| vibration.raw.v2 | 582,022 | **12** |

BAD แยกตาม asset:

| Asset | BAD rows |
|-------|----------|
| motor_04 | 430 |
| motor_03 | 417 |
| motor_01 | 265 |
| motor_02 | 237 |

Sparse payload (v2 BAD): มีแค่ `device_available`, `device_error`, `quality_detail`, `source_topic`

### Preview Q2/Q5 — Avg RMS velocity (GOOD, full payload)

| Motor | Avg x_rms_velocity_mm_s |
|-------|-------------------------|
| **motor_02** | **10.70** |
| motor_01 | 2.11 |
| motor_04 | 1.50 |
| motor_03 | 0.72 |

> motor_02 สูงกว่ามotor อื่นมาก — สอดคล้อง scenario (สั่นหนัก, ต้องดู ISO Zone)

---

## Domain 3: Power (`power_meter.raw.v1`)

### ข้อมูลทั่วไป

| รายการ | ค่า |
|--------|-----|
| Assets | MAIN-MDB, PM-F1 ถึง PM-F7 (8 meters) |
| ช่วงเวลา (UTC) | 2026-05-22 10:17:00 → 2026-06-20 09:20:00 |
| ความถี่ | ทุก 60 วินาที (~11,520 rows/วัน/meter) |
| Sparse payload | 5 แถว (มีแค่ `source_topic`) |

### Meter Hierarchy

```
MAIN-MDB (รวมทั้งโรงงาน)
  ├── PM-F1 (Floor 1)
  ├── PM-F2 (Floor 2)
  ├── PM-F3 (Floor 3)  ← ⚠️ anomaly
  ├── PM-F4 – PM-F7
```

### PM-F3 vs MAIN-MDB Anomaly

Avg `eq_active_power` (full payload):

| Meter | Avg kW |
|-------|--------|
| MAIN-MDB | 66.59 |
| **PM-F3** | **66.57** |
| PM-F1 | 7.06 |
| PM-F4 | 3.86 |
| PM-F5 | 3.83 |
| PM-F6 | 2.57 |
| PM-F7 | 1.09 |
| PM-F2 | 0.12 |

PM-F3 อ่านใกล้ MAIN-MDB แทนที่จะเป็น sub-meter ชั้น 3 — สอดคล้อง scenario (wiring/config issue)

### การคำนวณ Energy (สำคัญสำหรับ Q3/Q6)

- `total_import_active_energy` เป็น **cumulative counter** (kWh สะสม)
- ต้อง `MAX - MIN` ภายใน window (hour/day) ต่อ meter — **ห้าม SUM โดยตรง**
- ต้องเช็ค counter reset / non-monotonic ก่อนสร้าง pipeline

---

## QUALITY Summary (ทุก Domain)

| SCHEMA_VERSION | GOOD | BAD |
|----------------|------|-----|
| 0.1 | 25,636,014 | 0 |
| power_meter.raw.v1 | 302,117 | 0 |
| vibration.raw.v1 | 572,425 | 1,337 |
| vibration.raw.v2 | 582,022 | 12 |

Production และ Power ไม่มี BAD — ปัญหา quality อยู่ที่ Vibration เท่านั้น

---

## Timeline ข้อมูล (UTC)

```
22 พ.ค. ─── vibration v1 + power meter เริ่ม
26 พ.ค. ─── production เริ่ม
11 มิ.ย. ─── vibration v1 สิ้นสุด (04:58) → gap → v2 เริ่ม (12:26)
14 มิ.ย. ─── วันเสาร์ — energy drop ~80% (scenario)
15 มิ.ย. ─── peak energy day (scenario)
20 มิ.ย. ─── ข้อมูลสิ้นสุด
```

---

## Data Quality Issues (สำหรับ DESIGN.md §3)

| # | Issue | Impact | แนวทางจัดการ (draft) |
|---|-------|--------|----------------------|
| 1 | PAYLOAD เป็น VARCHAR | Silver extract ผิดถ้าไม่ parse | `PARSE_JSON(PAYLOAD)` ใน Silver transform |
| 2 | Production dual format (3s/60s) | State/delta field ชื่อต่างกัน | Unified columns ใน Silver + mapping table |
| 3 | ALWAYS_RUNNING (FM48/51/44) | Uptime สูงเกินจริง | Flag ใน MACHINE_CONFIG, exclude จาก throughput |
| 4 | No Order (803105) ครอง downtime | Uptime ต่ำเกินจริง | EXCLUDED category ใน DOWNTIME_CATEGORY |
| 5 | Vibration QUALITY=BAD | RMS/ISO ไม่น่าเชื่อถือ | Filter หรือ quarantine table |
| 6 | Vibration v1→v2 gap | ขาดข้อมูลช่วง firmware update | บันทึก gap, ไม่ interpolate |
| 7 | PM-F3 ≈ MAIN-MDB | Floor-level energy ผิด | Flag meter, ไม่ใช้ PM-F3 สำหรับ floor 3 |
| 8 | Cumulative energy counter | Double-count ถ้า SUM ตรงๆ | Diff ภายใน time window |
| 9 | Timestamp UTC | Shift/cost ผิดถ้าไม่ convert | `CONVERT_TIMEZONE('UTC','Asia/Bangkok', EVENT_TS)` |
| 10 | Duplicate EVENT_TS (ยังไม่ได้เช็ค) | Pipeline อาจ duplicate | MERGE + dedup key ใน Silver |

---

## Query ที่ใช้สำรวจ (copy-paste ได้)

```powershell
cd c:\Users\pubpuy\Desktop\appomax-test
.\scripts\activate-snow.ps1
```

### โครงสร้าง + ปริมาณ

```sql
DESCRIBE TABLE DE_CHALLENGE.BRONZE.RAW_EVENTS;

SELECT SCHEMA_VERSION, COUNT(*) AS cnt
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
GROUP BY 1 ORDER BY cnt DESC;

SELECT TYPEOF(PAYLOAD) FROM DE_CHALLENGE.BRONZE.RAW_EVENTS LIMIT 1;
```

### Payload keys ต่อ domain

```sql
SELECT SCHEMA_VERSION, OBJECT_KEYS(PARSE_JSON(PAYLOAD)) AS payload_keys
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
GROUP BY 1, 2
ORDER BY 1, 2
LIMIT 30;
```

### Production state codes

```sql
SELECT PARSE_JSON(PAYLOAD):n3_state_code::INT AS state_code,
       PARSE_JSON(PAYLOAD):n3_status_code::INT AS status_code,
       COUNT(*) AS cnt
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
WHERE SCHEMA_VERSION = '0.1'
  AND PARSE_JSON(PAYLOAD):n3_state_code IS NOT NULL
GROUP BY 1, 2
ORDER BY cnt DESC;
```

### QUALITY = BAD

```sql
SELECT SCHEMA_VERSION, QUALITY, COUNT(*) AS cnt
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
GROUP BY 1, 2
ORDER BY 1, cnt DESC;

SELECT ASSET, COUNT(*) AS bad_cnt
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
WHERE QUALITY = 'BAD'
GROUP BY 1 ORDER BY bad_cnt DESC;
```

### Timestamp range

```sql
SELECT SCHEMA_VERSION,
       MIN(EVENT_TS) AS min_ts,
       MAX(EVENT_TS) AS max_ts,
       COUNT(DISTINCT ASSET) AS assets
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
GROUP BY SCHEMA_VERSION
ORDER BY SCHEMA_VERSION;
```

### Query เพิ่มเติม (รันแล้ว — พร้อม Step 2)

```sql
-- Energy counter reset → ไม่พบ (monotonic ทุก meter)
-- Duplicate EVENT_TS → 73,131 groups, +73,636 extra rows (ส่วนใหญ่ production)
-- Weekend vs weekday → ลด ~62.4% (avg 704 vs 1,870 kWh/วัน)
```

---

## Step 1 Supplement — สำรวจเพิ่ม (22 มิ.ย. 2026)

### Duplicates (ต้อง handle ใน Silver MERGE)

| SCHEMA_VERSION | Duplicate groups `(ASSET, EVENT_TS)` | Extra rows |
|----------------|-------------------------------------|------------|
| 0.1 (production) | 71,021 | ~ส่วนใหญ่ |
| vibration.raw.v1 | 1,396 | |
| power_meter.raw.v1 | 713 | |
| vibration.raw.v2 | 1 | |
| **รวม** | **73,131** | **73,636** |

→ Silver pipeline ต้อง **idempotent (MERGE)** — ไม่ใช่ optional

### Energy counter

- **ไม่พบ reset** (`energy < prev`) ทุก meter — ใช้ `MAX - MIN` ได้อย่างปลอดภัย

### Q1 Preview — ทำไม Group3 ผลิตน้อยกว่า Group1?

| Group | เครื่อง | Running % | Setup % | No Order % | Mat. Shortage % | Mech. Fault % |
|-------|---------|-----------|---------|------------|-----------------|---------------|
| Group1 | 13 | **50.4** | 17.4 | 22.8 | 1.7 | 7.7 |
| Group2 | 11 | 35.2 | 13.2 | 39.6 | 9.9 | 1.1 |
| **Group3** | **6** | **25.7** | 12.5 | **45.5** | **13.9** | 0.0 |
| Group4 | 8 | 16.3 | 23.3 | 55.8 | 3.0 | 0.0 |

**Story สำหรับ present:**
1. Group3 **running ครึ่งหนึ่งของ Group1** (25.7% vs 50.4%) แม้ normalize ต่อเครื่องแล้ว
2. Group3 ใช้เวลา **No Order 45.5%** vs Group1 22.8% — สาเหตุหลัก: **ไม่มี work order** ไม่ใช่เครื่องเสีย
3. Group3 มี **Material Shortage 13.9%** สูงสุด — รอวัตถุดิบ
4. Group3 มีแค่ **6 เครื่อง** vs Group1 มี 13 — capacity น้อยกว่า
5. FM51 (Group3) เป็น **ALWAYS_RUNNING** — ดู running 77% แต่ producing 0%

### Q4 Preview — Setup time สูงสุด

| เครื่อง | Group | Setup % | Setup hours (est.) |
|---------|-------|---------|-------------------|
| FM52 | Group2 | 59.6% | ~319 ชม. |
| FM42 | Group1 | 44.4% | ~238 ชม. |
| FM31 | Group4 | 37.9% | ~203 ชม. |

*(est. = จำนวน readings state 801 × 3 วิ / 3600)*

### Q2 Preview — ISO Zone (avg RMS, ISO 10816 Class II)

| Motor | Avg RMS (mm/s) | ISO Zone |
|-------|----------------|----------|
| **motor_02** | **10.7** | **C** (Alert — วางแผนซ่อม) |
| motor_01 | 2.11 | B |
| motor_04 | 1.50 | A |
| motor_03 | 0.72 | A |

### Q5 Preview — motor_02 trend (weekly avg RMS)

| สัปดาห์ (local) | Avg RMS |
|-----------------|---------|
| 18–24 พ.ค. | 7.14 |
| 25–31 พ.ค. | 11.43 |
| 1–7 มิ.ย. | 8.02 |
| 8–14 มิ.ย. | 10.60 |
| 15–20 มิ.ย. | **12.62** |

→ **แนวโน้มแย่ลง** โดยเฉพาะสัปดาห์สุดท้าย (ใกล้ Zone D ที่ 11.2)

### Vibration v1 vs v2

| Version | Avg RMS | Avg RPM | Rows (GOOD, full) |
|---------|---------|---------|-------------------|
| v1 | 3.67 | 1,725 | 572,425 |
| v2 | 3.88 | 1,725 | 582,022 |

Key names เหมือนกัน — ค่าเฉลี่ย RMS ใกล้เคียง (ไม่ broken หลัง migration)

### Q3 Preview — ชั้นไหนใช้ไฟมากสุด (avg daily kWh, ไม่รวม PM-F3)

| Meter | Floor | Avg daily kWh |
|-------|-------|---------------|
| PM-F1 | 1 | **158** |
| PM-F4 | 4 | 87 |
| PM-F5 | 5 | 86 |
| PM-F6 | 6 | 58 |
| PM-F7 | 7 | 25 |
| PM-F2 | 2 | 3 |

### Q6 Preview — วันหยุด vs วันทำงาน (MAIN-MDB)

| Metric | ค่า |
|--------|-----|
| Avg weekday daily kWh | 1,870 |
| Avg weekend daily kWh | 704 |
| **ลดลง** | **62.4%** |

ตัวอย่างวันจริง:

| วันที่ (local) | kWh | หมายเหตุ |
|---------------|-----|----------|
| 13 มิ.ย. (ศ.) | 868 | วันทำงาน |
| **14 มิ.ย. (ส.)** | **389** | โรงงานปิด ~80% (scenario) |
| **15 มิ.ย. (จ.)** | **2,286** | peak day (scenario) |

Avg kW by day-of-week: Wed 89 → Sun **16** kW

### Power Factor

| Meter | Avg PF | Rows PF < 0.85 |
|-------|--------|----------------|
| **PM-F2** | **0.844** | 24,160 (64%) |
| PM-F5 | 0.880 | 16,093 |
| PM-F1 | 0.888 | 14,154 |
| PM-F4 | 0.971 | 113 |

→ PM-F2 มี PF ต่ำสุด — ควร flag ใน Plant Health dashboard

### Production dual format (ยืนยัน)

- ทุก 38 เครื่องมี **ทั้ง 3s และ 60s** (~643K + ~32K rows/เครื่อง)
- ไม่มีเครื่องที่ 60s-only

---

### Query เพิ่มเติม (archive — รันแล้ว)

```sql
-- Energy counter reset
SELECT ASSET, COUNT(*) AS resets
FROM (
  SELECT ASSET,
         PARSE_JSON(PAYLOAD):total_import_active_energy::FLOAT AS energy,
         LAG(PARSE_JSON(PAYLOAD):total_import_active_energy::FLOAT)
           OVER (PARTITION BY ASSET ORDER BY EVENT_TS) AS prev
  FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
  WHERE SCHEMA_VERSION = 'power_meter.raw.v1'
    AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) > 5
) t
WHERE energy < prev
GROUP BY 1;

-- Weekend vs weekday (preview Q6)
SELECT DAYNAME(CONVERT_TIMEZONE('UTC','Asia/Bangkok', EVENT_TS)) AS dow,
       AVG(PARSE_JSON(PAYLOAD):eq_active_power::FLOAT) AS avg_kw
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
WHERE SCHEMA_VERSION = 'power_meter.raw.v1' AND ASSET = 'MAIN-MDB'
  AND ARRAY_SIZE(OBJECT_KEYS(PARSE_JSON(PAYLOAD))) > 5
GROUP BY 1 ORDER BY 2 DESC;

-- Duplicate EVENT_TS
SELECT COUNT(*) AS dup_groups FROM (
  SELECT ASSET, EVENT_TS, COUNT(*) AS c
  FROM DE_CHALLENGE.BRONZE.RAW_EVENTS
  GROUP BY 1, 2 HAVING c > 1
);
```

---

## Checklist Step 1 (PLAN.md)

| รายการ | สถานะ |
|--------|-------|
| DESCRIBE TABLE | ✅ |
| OBJECT_KEYS แยก domain | ✅ |
| Sample payload แต่ละ domain | ✅ |
| QUALITY = BAD | ✅ |
| State codes production | ✅ |
| Timestamp range | ✅ |
| จด data quality issues | ✅ (ไฟล์นี้) |
| สำรวจเพิ่ม (duplicates, energy, Q1–Q6 preview) | ✅ (Supplement ด้านบน) |

---

## ผลกระทบต่อ Task ถัดไป

### Task 1 — Schema Design

- Silver ต้องมี `PARSE_JSON` layer หรือ cast PAYLOAD เป็น VARIANT ตอน insert
- Production Silver: unified columns สำหรับ 2 formats + computed `IS_PRODUCING`, `DOWNTIME_CATEGORY`
- Vibration Silver: รองรับ v1/v2 ใน table เดียว + `ISO_ZONE`, `MACHINE_STATE`
- Power Silver: `HOURLY_KWH` จาก cumulative diff + `IS_PEAK_HOUR`

### Task 2 — Silver Pipeline

- MERGE key: `(ASSET, EVENT_TS, SCHEMA_VERSION)` หรือ equivalent — รองรับ duplicate retry
- Quarantine table สำหรับ Vibration BAD + sparse payloads
- Timezone convert ที่ Silver (แนะนำ) เพื่อใช้ซ้ำใน Gold

### Reference Tables ที่ต้องสร้าง (Task 3)

- `MACHINE_CONFIG` — group, ALWAYS_RUNNING flag
- `REASON_CODE_LOOKUP` — 803105, 803101, 803112 ฯลฯ
- `SHIFT_DEFINITIONS` — 4 กะ GMT+7
- `ENERGY_RATE_CONFIG` — peak/off-peak

---

## อ้างอิง

- [`PLAN.md`](../../PLAN.md) — Step 1 checklist
- [`scenario.md`](../../scenario.md) — บริบทธุรกิจ + timeline
- [`reference/data_dictionary.md`](../../reference/data_dictionary.md) — field definitions
- [`reference/uns_schema.md`](../../reference/uns_schema.md) — UNS hierarchy + schema versions
