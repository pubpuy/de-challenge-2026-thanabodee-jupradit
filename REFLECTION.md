# REFLECTION.md

โจทย์ DE Challenge 2026 — Compomax

---

## สิ่งที่เรียนรู้

Medallion ใน slide กับของจริง 26 ล้านแถวใน table เดียว มันคนละเรื่อง สิ่งที่ใช้บ่อยสุดคือ Stream + Task + MERGE ที่ Silver เพราะ Bronze มี duplicate จาก delivery retry อยู่แล้ว รันซ้ำแล้วไม่พองข้อมูล

Step 1 สำคัญกว่าที่คิด `PAYLOAD` เป็น VARCHAR ไม่ใช่ VARIANT ต้อง `PARSE_JSON` ก่อน extract ทุกครั้ง timezone convert ที่ Silver (`EVENT_TS_LOCAL`) เพราะกะ Compomax เริ่ม 00:45 ไม่ใช่ 08:00 และ timestamp ใน Bronze เป็น UTC

อีกอย่างคือ business rule ไม่ได้อยู่ใน schema เช่น No Order (803105) กับเครื่อง ALWAYS_RUNNING (FM51 ดู running 77% แต่ counter ไม่เดิน) Power meter เป็น cumulative ห้าม SUM ตรงๆ ต้อง diff ต่อชั่วโมงใน Gold Snowflake CLI ช่วยให้ deploy SQL/Streamlit จาก local ได้โดยไม่ copy ทั้งไฟล์เข้า worksheet

---

## ปัญหาที่เจอ และวิธีแก้

Production มี 2 payload format (3s / 60s) ใต้ schema version เดียว แก้ด้วย unified columns (`STATE_CODE`, `PARTS_DELTA`) ใน Silver

Duplicate 73K+ groups ใช้ MERGE ON `EVENT_ID` Vibration BAD quality 1,349 rows ส่งไป `VIBRATION_QUARANTINE` ไม่ filter ทิ้งเงียบๆ

PM-F3 อ่านค่าใกล้ MAIN-MDB (66.57 vs 66.59 kW) flag `IS_ANOMALY` แล้ว exclude จาก floor sum แต่เก็บ row ไว้ audit

Backfill 25M rows บน trial warehouse ช้าและกิน credit incremental ด้วย Stream เลยจำเป็น ไม่ใช่ optional

Streamlit deploy ครั้งแรก tab Energy ไม่ขึ้น เพราะแก้ code หลัง deploy แล้ว ต้อง `snow streamlit deploy --replace` อีกรอบ

---

## ถ้ามีเวลา 2 สัปดาห์เพิ่ม

ลอง Dynamic Table แทน SP+Task ที่ Gold ทำ alert (Zone D, uptime < 50%) แทนแค่ดูใน dashboard เพิ่ม shift-level energy drill-down ต่อ floor และ watermark table ไว้ debug ตอน task fail Cortex ML (Option C) น่าสนใจ แต่จะทำหลัง data quality นิ่งก่อน โดยเฉพาะ gap v1→v2 7.5 ชม.

---

AI ช่วยเขียน SQL boilerplate กับ Streamlit ได้เยอะ แต่ decision อย่าง EXCLUDED สำหรับ 803105 หรือ PM-F3 flag แต่ไม่ลบ ต้องมาจากอ่าน reference แล้ว query เอง ส่วนนั้นยังทำเอง
