# project cyber - ห้องทดลองทดสอบความปลอดภัยเว็บ bWAPP อัตโนมัติ

ห้องทดลอง penetration testing ที่ทำซ้ำได้ สร้างได้เองทั้งหมด (self-contained) สำหรับ
[bWAPP](https://github.com/raesene/bWAPP) มีเทสต์เคส HTTP ทั้งหมด 122 กรณี
ซึ่งถูกส่งและตรวจสอบผลลัพธ์อัตโนมัติ พร้อมหลักฐานครบทุกข้อ

ทุกอย่างทำงานกับ container Docker แบบใช้แล้วทิ้ง บน `127.0.0.1:8080`
ไม่มีสิ่งใดในโปรเจกต์นี้แตะเครือข่ายที่คุณไม่ได้เป็นเจ้าของ

```
TOTAL: 122   PASS: 117   FAIL: 0   SKIP/PLANNED: 5   decided: 95.9%
```

## ความต้องการระบบ

- Windows PowerShell 5.1 (หรือ PowerShell 7) - สคริปต์เขียนสำหรับ 5.1
- Docker Desktop ที่กำลังทำงานอยู่
- ไม่ต้องมีอะไรอื่น ไม่ต้องติดตั้ง PHP, MySQL client, `gh` หรือ Python บนเครื่อง host

## เริ่มใช้งาน

```powershell
# 1. สตาร์ตแล็บ, seed ฐานข้อมูล, ปรับสิทธิ์โฟลเดอร์สำหรับอัปโหลด
.\scripts\setup-bwapp.ps1 -Reset

# 2. รันเทสต์ทั้งหมดและบันทึก response
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence

# 3. เริ่มต้นใหม่ทั้งหมด
.\scripts\setup-bwapp.ps1 -Reset
```

`setup-bwapp.ps1` เป็นขั้นตอนเดียวที่จำเป็นจริง ๆ ขั้นตอนที่ 2 จะเข้าสู่ระบบเอง
และไม่ต้องตั้งค่าอะไรเพิ่ม

ถ้าชอบใช้ Compose: `docker compose up -d` แล้วรัน `setup-bwapp.ps1` โดยไม่ใส่
`-Reset` - ตรรกะการ seed เหมือนกันทุกประการ

## สิ่งที่สคริปต์ setup แก้ไข

image `raesene/bwapp:latest` สตาร์ตได้ แต่ถ้านำมาใช้ตามสภาพจะไม่ทำงาน:

| ปัญหา | สิ่งที่สคริปต์ทำ |
| --- | --- |
| MySQL สตาร์ต **ว่างเปล่า** - ทุกหน้าที่อ่านข้อมูลจะ error | อ่าน `/var/www/html/db/bwapp.sqlite` จากใน container แล้วเล่นซ้ำเข้า MySQL โดยแปลงทั้ง DDL และข้อมูล |
| SQLite ไม่มี `AUTO_INCREMENT` ทำให้ `blog.id` ไม่ถูกกำหนดค่าอัตโนมัติ และ INSERT ครั้งที่สองชนกันที่ `id 0` | คืน `AUTO_INCREMENT` ให้คอลัมน์ที่เป็น primary key แบบ integer คอลัมน์เดียว |
| ผู้ใช้ฐานข้อมูลของแอปมองไม่เห็นตารางที่ import มา | `GRANT ALL ON bWAPP.*` |
| `images/`, `documents/` และ `logs/` เป็น read-only สำหรับ `www-data` ทำให้ยืนยันช่องโหว่ file upload ไม่ได้ | `chmod 0777` ทั้งสามโฟลเดอร์ |
| ยังไม่มี session ที่ใช้ได้สำหรับชุดเทสต์ | เข้าสู่ระบบในชื่อ `bee`, ตรวจสอบ 302 แล้วเขียน `PHPSESSID` ที่ใช้งานได้ลงใน `http-client.env` |

สคริปต์เป็น idempotent: รันสองครั้ง ครั้งที่สองจะรายงานว่า `schema already present`
และไม่แก้อะไรเลย

## โครงสร้างโปรเจกต์

```
http-client.env            ตัวแปรร่วมสำหรับไฟล์ .http (อยู่ใน .gitignore;
                           http-client.env.example คือเทมเพลตที่ track ไว้)
http/*.http                ชุดเทสต์ - HTTP ล้วน ไม่พึ่งเฟรมเวิร์กใด
scripts/setup-bwapp.ps1    สร้างแล็บขึ้นมาจากศูนย์
scripts/Run-HttpFile.ps1   ตัว parse, ส่ง, ตรวจสอบ และสรุปผลของไฟล์ .http
scripts/validate.ps1       ตัวตรวจสอบแบบ batch รุ่นเก่า เก็บไว้เป็นมุมมองที่สอง
scripts/probe.ps1          ยิง request เดี่ยว ๆ ที่ล็อกอินแล้ว เอาไว้เดิ
evidence/                  response ที่บันทึกไว้ (อยู่ใน .gitignore, ~10 MB)
docs/report.md             รายงานช่องโหว่ทั้งหมด
```

## runner สองตัว

`Run-HttpFile.ps1` คือตัวหลัก มันอ่านไฟล์ `.http` เดิม ทำให้เทสต์ยังอ่านเข้าใจง่าย
และส่งด้วยมือจาก VS Code (REST Client) หรือ JetBrains ได้ด้วย
แต่ละ request มี assertion แบบให้เครื่องตรวจได้เอง:

```http
### XSS-01 Reflected, GET parameters
GET {{baseUrl}}/xss_get.php?firstname=%3Cscript%3Ealert(1)%3C%2Fscript%3E&lastname=x HTTP/1.1

> {% response.status %}
```

- `> {% response.status %}` - status ที่คาดหวัง, `200|302` ได้เมื่อมีหลายค่า
- `> {% response.body %}` - ข้อความย่อยที่ต้องมีอยู่
- `> {% response.header.X %}` - ค่า header ที่คาดหวัง
- `> {% response.time %}` - assertion ด้านเวลา ใช้กับ blind injection
- `> {% not.response.body %}` - **negative control**: ข้อความที่ต้อง *ไม่* มี
- บรรทัดท้าย `# Expect: ...` - เขียนความหมายแบบบรรยาย สำหรับ editor ที่ไม่เข้าใจ
  syntax ข้างบน

สวิตช์ที่ใช้บ่อย:

```powershell
-File 'http\*.http'     # glob, ไฟล์เดียว หรือหลายไฟล์
-Only 'SQLI-*'          # กรองตาม test id
-SaveEvidence           # เขียนทุก response ลง evidence/
-ShowBody               # แสดง body ของเคสที่ fail
-UpdateEnv              # เขียน session ที่ใช้งานได้กลับลง http-client.env
-ReportOnly             # พิมพ์ผลรอบก่อนหน้าอีกครั้งโดยไม่ยิง request
-NoAutoLogin            # ใช้ session ที่มีอยู่ใน env file
```

ตัว runner จัดการเรื่องที่ทำให้ชุดเทสต์ `.http` กวนใจในทางปฏิบัติ ได้แก่
การแทรคค่า `{{variable}}`, cookie jar และ**เข้าสู่ระบบใหม่อัตโนมัติระหว่างไฟล์**
(`logout.php` ของ bWAPP ทำลาย session และไฟล์ที่จบด้วยการ logout จะไปทำให้
ทุกไฟล์หลังจากนั้นพัง ถ้าไม่จัดการ)

`validate.ps1` เป็นอีกชุดที่เขียนแยกอิสระ - 75 เคส ใช้คนละ code path และ assertion
ของตัวเอง ช้ากว่าและละเอียดกว่า แต่เวลาสองตัวไม่ตรงกัน นั่นคือสัญญาณที่มีความหมาย
ไม่ใช่สัญญาณรบกวน ปัจจุบันทั้งสองตัวรายงานว่าไม่มีเคสไหนล้มเหลว และรันซ้ำบน
container เดิมได้

## ผลการทดสอบ

| ชุด | เคส | ผ่าน | ไม่ผ่าน | ข้าม (planned) |
| --- | --- | --- | --- | --- |
| `Run-HttpFile.ps1` | 122 | 117 | 0 | 5 |
| `validate.ps1` | 75 | 75 | 0 | 0 |

ครอบคลุม: SQL injection (15), XSS รวมแบบ stored และผ่าน cookie (14),
local file read และ source disclosure (9), OS command และ PHP injection (11),
XXE/XML injection (7), mail header injection (2), unrestricted upload (4),
ช่องโหว่ด้าน authentication และ session (14), CSRF (4), clickjacking (2),
CORS (3), information disclosure (17), host header และ HTTP verb (5)
และผิวโค้ง DoS (2)

5 เคสที่ถูกข้ามเป็น **ข้อจำกัดของ client ไม่ใช่ช่องโหว่ที่ยังไม่ได้ทดสอบ**
`System.Uri` และ `HttpWebRequest` ปฏิเสธที่จะส่ง request line ที่ผิดรูปแบบ
แต่ละเคสถูกทำเครื่องหมาย `PLANNED` พร้อมเหตุผลในผลลัพธ์ และแต่ละเคสถูกยืนยัน
ด้วยมือกับเป้าหมายจริงแล้ว ดูรายละเอียดที่
[docs/report.md](docs/report.md)

## ความปลอดภัย

image นี้เต็มไปด้วย RCE, SQL injection และ LFI ที่ไม่ต้องล็อกอินโดยเจตนา

- พอร์ตผูกกับ `127.0.0.1` เท่านั้น ห้าม publish ออกไป
- ไม่มี volume mount เด็ดขาด เพื่อไม่ให้ webshell ที่อัปโหลดหลุดออกมานอก container
- container ใช้แล้วทิ้งได้ `-Reset` คือการลบทิ้งทั้งตัว

## หลักฐาน

`evidence/` มีไฟล์หนึ่งไฟล์ต่อหนึ่ง response ที่ตรวจสอบแล้ว ตั้งชื่อตามชื่อเทสต์
แต่ละไฟล์มี request ที่ส่งและ response เต็ม ทำให้ตรวจสอบข้อค้นพบซ้ำได้โดยไม่ต้องรันอะไรใหม่:

```powershell
Get-Content .\evidence\INFO-01_CRITICAL___admin__publishes_the_credentials_.txt -TotalCount 40
```

## ภาษา

เอกสารและคอมเมนต์ในโค้ดเป็นภาษาไทย แต่ชื่อเทสต์ในไฟล์ `.http` คงเป็นภาษาอังกฤษ
โดยตั้งใจ เพราะ runner ใช้ชื่อเทสต์ไปสร้างชื่อไฟล์ใน `evidence/` และใช้เป็น
test id ในการกรองด้วย `-Only` ถ้าเป็นภาษาไทย ตัวกรอง
`[^A-Za-z0-9._-]` ใน `Run-HttpFile.ps1` จะแปลงอักขระทั้งหมดเป็น `_`
ทำให้ชื่อไฟล์อ่านไม่ออก
