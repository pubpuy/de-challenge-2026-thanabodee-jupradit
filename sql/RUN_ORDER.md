# SQL Run Order

รันไฟล์ใน `sql/` ตามลำดับด้านล่าง (Snowsight หรือ Snowflake CLI)  
แต่ละไฟล์รันจากบนลงล่างภายในไฟล์เดียวกัน

## ลำดับหลัก (Production + Vibration + Dashboard)

| # | ไฟล์ | ทำอะไร | ขึ้นกับ |
|---|------|--------|---------|
| 1 | [`00_setup.sql`](00_setup.sql) | สร้าง DB, schemas, warehouse, ตาราง `BRONZE.RAW_EVENTS` | — |
| 2 | [`01_load_from_s3.sql`](01_load_from_s3.sql) | โหลดข้อมูลจาก S3 → Bronze (~26M rows, ใช้เวลา 3–5 นาที) | 1 |
| 3 | [`02_silver_schema.sql`](02_silver_schema.sql) | DDL ตาราง Silver (Production + Vibration) | 2 |
| 4 | [`02_silver_pipeline.sql`](02_silver_pipeline.sql) | Stream, SP, Task, backfill Silver Prod/Vib | 3 |
| 5 | [`03_gold_aggregation.sql`](03_gold_aggregation.sql) | Reference tables + Gold Prod/Vib + Tasks | 4 |
| 6 | [`04_capstone_streamlit.sql`](04_capstone_streamlit.sql) | Stage + Streamlit object (หรือใช้ `snow streamlit deploy`) | 5 |

## Phase 2 — Energy / Power (Q3, Q6)

รันหลังขั้นตอนที่ 4 เสร็จ (Silver Prod/Vib โหลดแล้ว)

| # | ไฟล์ | ทำอะไร | ขึ้นกับ |
|---|------|--------|---------|
| 5a | [`02_silver_power.sql`](02_silver_power.sql) | DDL + pipeline Silver Power | 3 |
| 5b | [`03_gold_energy.sql`](03_gold_energy.sql) | Gold Energy hourly/daily + Task | 5a |

> ถ้าทำ Energy ครบ: รัน **5a → 5b** ก่อนขั้นที่ 6 (Dashboard)  
> Dashboard ใช้ Production + Vibration เป็นหลัก — Energy เป็น optional สำหรับ Q3/Q6

## สรุปเร็ว

```
00_setup
  → 01_load_from_s3
    → 02_silver_schema
      → 02_silver_pipeline
        → 03_gold_aggregation
          → 04_capstone_streamlit

(+ Phase 2: 02_silver_power → 03_gold_energy  หลัง 02_silver_schema)
```

## หมายเหตุ

- **Backfill** อยู่ใน `02_silver_pipeline.sql` (§5) และ `02_silver_power.sql` (§5) — รันครั้งแรกหลัง deploy pipeline
- **Tasks** ใน pipeline ไฟล์จะ `RESUME` อัตโนมัติบางตัว — ตรวจด้วย `SHOW TASKS IN SCHEMA DE_CHALLENGE.SILVER`
- **Streamlit deploy แนะนำ:** `snow streamlit deploy` จาก `snowflake.yml` แทนรัน §2 ใน `04_capstone_streamlit.sql` ด้วยมือ
