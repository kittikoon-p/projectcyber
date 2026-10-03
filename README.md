# project cyber - ห้องทดลองทดสอบความปลอดภัยเว็บ bWAPP อัตโนมัติ

ห้องทดลอง penetration testing ที่ทำซ้ำได้ สร้างได้เองทั้งหมด (self-contained) สำหรับ
[bWAPP](https://github.com/raesene/bWAPP) มีเทสต์เคส HTTP ทั้งหมด 122 กรณี
ซึ่งถูกส่งและตรวจสอบผลลัพธ์อัตโนมัติ พร้อมหลักฐานครบทุกข้อ

ทุกอย่างทำงานกับ container Docker แบบใช้แล้วทิ้ง บน `127.0.0.1:8443`
ไม่มีสิ่งใดในโปรเจกต์นี้แตะเครือข่ายที่คุณไม่ได้เป็นเจ้าของ

```
TOTAL: 122   PASS: 117   FAIL: 0   SKIP/PLANNED: 5   decided: 95.9%
```

รายงานช่องโหว่ทั้งหมดอยู่ใน [docs/report.md](docs/report.md)

## Quick start

```powershell
# 1. สตาร์ตแล็บ, seed ฐานข้อมูล, ปรับสิทธิ์โฟลเดอร์สำหรับอัปโหลด
.\scripts\setup-bwapp.ps1 -Reset

# 2. รันเทสต์ทั้งหมด บันทึก response แล้วสร้างหน้าเว็บสรุปผล
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence -Dashboard

# 3. เปิด dashboard.html ด้วยเบราว์เซอร์

# 4. เริ่มต้นใหม่ทั้งหมด
.\scripts\setup-bwapp.ps1 -Reset
```

`setup-bwapp.ps1` เป็นขั้นตอนเดียวที่จำเป็นจริง ๆ ขั้นตอนที่ 2 จะเข้าสู่ระบบเอง
และไม่ต้องตั้งค่าอะไรเพิ่ม

ถ้าชอบใช้ Compose ก็ได้ ตรรกะการ seed เหมือนกันทุกประการ เพียงต้อง **ไม่ใส่
`-Reset`** เพราะ `-Reset` จะไป `docker rm` container ที่ Compose สร้างไว้

```powershell
docker compose up -d
.\scripts\setup-bwapp.ps1
```

## ความต้องการระบบ

- Windows PowerShell 5.1 (หรือ PowerShell 7) - สคริปต์เขียนสำหรับ 5.1
- Docker Desktop ที่กำลังทำงานอยู่
- ไม่ต้องมีอะไรอื่น ไม่ต้องติดตั้ง PHP, MySQL client, `gh` หรือ Python บนเคื่อง host
  (สคริปต์ที่ต้องใช้ Python จะรันอยู่ใน container)

## สิ่งที่สคริปต์ setup แก้ไข

image `raesene/bwapp:latest` สตาร์ตได้ แต่ถ้านำมาใช้ตามสภาพจะไม่ทำงาน:

| ปัญหา | สิ่งที่สคริปต์ทำ |
| --- | --- |
| MySQL สตาร์ต **ว่างเปล่า** - ทุกหน้าที่อ่านข้อมูลจะ error | อ่าน `/var/www/html/db/bwapp.sqlite` จากใน container แล้วเล่นซ้ำเข้า MySQL โดยแปลงทั้ง DDL และข้อมูล |
| SQLite ไม่มี `AUTO_INCREMENT` ทำให้ `blog.id` ไม่ถูกกำหนดค่าอัตโนมัติ และ INSERT ครั้งที่สองชนกันที่ `id 0` | คืน `AUTO_INCREMENT` ให้คอลัมน์ที่เป็น primary key แบบ integer คอลัมน์เดียว |
| ผู้ใช้ฐานข้อมูลของแอปมองไม่เห็นตารางที่ import มา | `GRANT ALL ON bWAPP.*` |
| `images/`, `documents/` และ `logs/` เป็น read-only สำหรับ `www-data` ทำให้ยืนยันช่องโหว่ file upload ไม่ได้ | `chmod 0777` ทั้งสามโฟลเดอร์ |
| ยังไม่มี session ที่ใช้ได้สำหรับชุดเทสต์ | เข้าสู่ระบบในชื่อ `bee`, ตรวจสอบ 302 แล้วเขียน `PHPSESSID` ที่ใช้ได้ลงใน `http-client.env` |

สคริปต์เป็น idempotent: รันสองครั้ง ครั้งที่สองจะรายงานว่า `schema already present`
และไม่แก้อะไรเลย

## โครงสร้างโปรเจกต์

```
docker-compose.yml          ทางเลือกแทนคำสั่ง docker run - publish ที่ 127.0.0.1:8443
http-client.env             ตัวแปรร่วมสำหรับไฟล์ .http (อยู่ใน .gitignore;
                            http-client.env.example คือเทมเพลตที่ track ไว้)
http/*.http                 ชุดเทสต์ 10 ไฟล์ - HTTP ล้วน ไม่พึ่งเฟรมเวิร์กใด
scripts/setup-bwapp.ps1     สร้างแล็บขึ้นมาจากศูนย์
scripts/Run-HttpFile.ps1    ตัว parse, ส่ง, ตรวจสอบ และสรุปผลของไฟล์ .http
scripts/validate.ps1        ตัวตรวจสอบแบบ batch รุ่นเก่า เก็บไว้เป็นมุมมองที่สอง
scripts/probe.ps1           ยิง request เดี่ยว ๆ ที่ล็อกอินแล้ว เอาไว้เดิ
scripts/New-Dashboard.ps1   สร้าง dashboard.html จากผลรอบล่าสุด
scripts/Test-Dashboard.js   ตรวจข้อมูลใน dashboard (ต้องมี Node.js)
scripts/Test-DashboardUi.js ตรวจพฤติกรรมตัวกรองในเบราว์เซอร์จริง (ต้องมี Node.js)
evidence/                   response ที่บันทึกไว้ (อยู่ใน .gitignore, ~10 MB, 117 ไฟล์)
dashboard.html              หน้าเว็บสรุปผล (อยู่ใน .gitignore, สร้างใหม่ได้เสมอ)
docs/report.md              รายงานช่องโหว่ทั้งหมด
```

## ตัวรันเทสต์หลัก (Run-HttpFile.ps1)

`Run-HttpFile.ps1` อ่านไฟล์ `.http` เดิม ทำให้เทสต์ยังอ่านเข้าใจง่าย
และส่งด้วยมือจาก VS Code (REST Client) หรือ JetBrains ได้ด้วย
แต่ละ request ระบุผลลัพธ์ที่คาดหวังไว้เหนือคำขอ ตัว runner อ่านได้ทั้ง
syntax เต็มและรูปแบบข้อความธรรมดา:

```http
### SQLI-07 Boolean blind - FALSE branch (control, proves the blind is real)
POST {{baseUrl}}/sqli_5.php HTTP/1.1
Content-Type: application/x-www-form-urlencoded

title=' AND 1=2 AND title='&action=search
### EXPECT-STATUS: 200
### EXPECT-NOT: The movie exists in our database!
```

### ไวยากรณ์ assertion

| รูปแบบ | ความหมาย |
| --- | --- |
| `### EXPECT-STATUS: 200` | status ที่ต้องตรงทั้งหมด เขียน `200\|302` ได้เมื่อยอมรับหลายค่า |
| `### EXPECT-BODY: ข้อความย่อย` | ข้อความที่ต้อง **มี** อยู่ใน body |
| `### EXPECT-NOT: ข้อความย่อย` | **negative control** - ข้อความที่ต้อง **ไม่มี** |
| `### EXPECT-HEADER: ชื่อ header` | ส่วนหัวการตอบกลับที่ต้องมีอยู่ (ยังไม่มีเทสต์ไหนใช้) |
| `### EXPECT-TIME-AT-LEAST: 500` | assertion ด้านเวลา ใช้กับ blind injection |
| `### SKIP` | รายงานเคสนี้แต่ไม่ส่งคำขอ (นับเป็น planned) |

รูปแบบข้อความธรรมดาสำหรับอ่านง่าย ใช้ได้กับ editor ที่ไม่เข้าใจ syntax ข้างบน
ตัว runner ดันจับให้เฉพาะ `### Expected: 200` และ `body contains "..."`
เท่านั้น บรรทัดอื่นที่เขียนเป็นคำบรรยาย เช่น `### Expected: 200, contains: uid=33(www-data)`
จะไม่ถูกนับเป็น assertion ระดับเนื้อหา

ตัว runner จัดการเรื่องที่ทำให้ชุดเทสต์ `.http` กวนใจในทางปฏิบัติได้แก่
การแทรคค่า `{{variable}}`, cookie jar และ**เข้าสู่ระบบใหม่อัตโนมัติระหว่างไฟล์**
(`logout.php` ของ bWAPP ทำลาย session และไฟล์ที่จบด้วยการ logout จะไปทำให้
ทุกไฟล์หลังจากนั้นพัง ถ้าไม่จัดการ)

### สวิตช์ที่ใช้บ่อย

```powershell
-File 'http\*.http'     # glob, ไฟล์เดียว หรือหลายไฟล์
-Only 'SQLI-*'          # กรองตาม test id
-SaveEvidence           # เขียนทุก response ลง evidence/
-Dashboard              # สร้าง dashboard.html ทันทีที่รันเสร็จ
-ShowBody               # แสดง body ของเคสที่ fail
-UpdateEnv              # เขียน session ที่ใช้ได้กลับลง http-client.env
-ReportOnly             # พิมพ์ผลรอบก่อนหน้าอีกครั้งโดยไม่ยิง request
-NoAutoLogin            # ใช้ session ที่มีอยู่ใน env file
-EnvFile <path>         # อ่านตัวแปรจากไฟล์อื่น (ค่าเริ่มต้นคือ http-client.env)
-KeepStaleEvidence      # ไม่ลบหลักฐาน .txt ที่ไม่อยู่ในรอบนี้
```

เมื่อรันครบทุกไฟล์ ตัว runner จะลบหลักฐาน `.txt` เก่าที่ไม่อยู่ในผลรอบนี้ทิ้ง
(ใช้ `-KeepStaleEvidence` เพื่อเก็บไว้ทั้งหมด)

### ขอบเขตของ PASS

เคสที่ไม่มี `EXPECT-*` เลยจะเริ่มต้นเป็น `PASS` และจะกลายเป็น `FAIL`
เฉพาะเมื่อได้ status >= 400 หรือถูกเด้งกลับ `login.php` (session หมด)
ดังนั้นตัวเลข PASS ที่รายงานเป็นการยืนยันว่า**เป้าหมายตอบกลับและ session ยังใช้ได้**
ไม่ใช่การยืนยันว่าช่องโหว่ทำงานจริง

ใน 117 เคสที่ตัดสินแล้ว มี **11 เคส** ที่ตรวจระดับเนื้อหาด้วย `EXPECT-BODY`
หรือ `EXPECT-NOT` และอีก **1 เคส** (`CMDI-09`) ที่ตรวจระดับเวลาด้วย
`EXPECT-TIME-AT-LEAST` - เคสนี้ยืนยัน blind command injection ด้วยการชะลอ
ประมาณ 5 วินาที เทียบกับเคสปกติที่ตอบในไม่กี่มิลลิวินาที ส่วนที่เหลืออีก
105 เคสตรวจระดับ status เป็นหลัก และเป็นงานรอบถัดไป

ข้อควรระวังเวลาเลือก marker: marker ที่กว้างเกินไปจะผ่านโดยไม่ได้ยืนยันอะไร
`bWAPP` ปรากฏใน 86 จาก 117 ไฟล์หลักฐาน และ `Did you captured our GOLDEN packet?`
เป็นข้อความในเทมเพลตของหน้า `commandi.php` ไม่ใช่ผลลัพธ์ของคำสั่งที่ inject
การยืนยัน oracle ของ blind injection ต้องใช้ `EXPECT-TIME-AT-LEAST`
ไม่ใช่ค้นหาข้อความใน body

## ผลการทดสอบ

| ชุด | เคส | ผ่าน | ไม่ผ่าน | ข้าม (planned) |
| --- | --- | --- | --- | --- |
| `Run-HttpFile.ps1` | 122 | 117 | 0 | 5 |
| `validate.ps1` | 75 | 75 | 0 | 0 |

ครอบคลุม 122 เคส แบ่งตามกลุ่มช่องโหว่ได้ดังนี้

| กลุ่ม | เคส |
| --- | --- |
| Baseline / ตรวจความยังมีชีวิตของเป้าหมาย (BOOT) | 6 |
| SQL injection (SQLI) | 15 |
| XSS reflected, stored, cookie, หลาย context (XSS) | 14 |
| Local file read และ source disclosure (LFI) | 9 |
| OS command injection (CMDI) และ PHP code injection (CODE) | 11 |
| XXE (XXE) และ XML injection (XXI) | 7 |
| Mail header injection (MAIL) | 2 |
| Unrestricted file upload (UPL) | 4 |
| Authentication และ session (AUTH) | 15 |
| CSRF | 4 |
| Clickjacking (CLICK) | 2 |
| CORS | 3 |
| Information disclosure, open redirect, header injection (INFO) | 19 |
| Host header (HOST) และ HTTP verb (VERB) | 6 |
| HTTP request smuggling (SM) | 3 |
| DoS | 2 |

### เคสที่ถูกข้าม (PLANNED)

5 เคสนี้เป็น **ข้อจำกัดของ client** ไม่ใช่ช่องโหว่ที่ยังไม่ได้ทดสอบ
`System.Net.HttpWebRequest` เป็น HTTP client เดียวที่ใช้ได้ใน Windows
PowerShell 5.1 โดยไม่ต้องติดตั้งอะไรเพิ่ม และมันเขียนทับส่วนที่ต้องการ
ควบคุมเอง ทุกเคสถูกยืนยันด้วยมือกับเป้าหมายจริงแล้ว ดูรายละเอียดที่
[docs/report.md](docs/report.md)

| ID | สิ่งที่ client เขียนทับ |
| --- | --- |
| `XSS-06` | `System.Uri` un-escape `%3C`/`%3E` ใน path เป็น `<` `>` ตรง ๆ ทำให้เซิร์ฟเวอร์ตอบ 404 |
| `SM-01` (ไฟล์ `07-`) | `Content-Length` / `Transfer-Encoding` ถูกเขียนใหม่ จึงไม่เกิดความไม่สอดคล้องกันแบบ CL/TE |
| `SM-01`, `SM-02` (ไฟล์ `09-`) | header `Transfer-Encoding` ซ้ำ ถูกยุบรวมให้เหลือค่าเดียว |
| `HOST-03` | request line แบบ absolute-form ถูกเขียนใหม่เป็น origin-form |

หมายเหตุ: `SM-01` ปรากฏในไฟล์ `07-csrf-clickjacking-cors.http` และ
`09-host-header-verbs.http` ทั้งคู่ เป็นคนละคำขอที่ทดสอบ surface เดียวกัน
(`docs/report.md` อ้างอิงด้วยชื่อไฟล์เพื่อแยกให้ชัด) ผลของมันคือ
**ไม่มี desync primitive** บน Apache 2.4 ของ image นี้ ไม่ใช่ช่องโหว่ที่พิสูจน์แล้ว

## ตัวตรวจสอบรุ่นที่สอง (validate.ps1)

`validate.ps1` เป็นอีกชุดที่เขียนแยกอิสระ - 75 เคส ใช้คนละ code path และ assertion
ของตัวเอง ช้ากว่าและละเอียดกว่า แต่เวลาสองตัวไม่ตรงกัน นั่นคือสัญญาณที่มีความหมาย
ไม่ใช่สัญญาณรบกวน ปัจจุบันทั้งสองตัวรายงานว่าไม่มีเคสไหนล้มเหลว และรันซ้ำบน
container เดิมได้

```powershell
.\scripts\validate.ps1
.\scripts\validate.ps1 -SecurityLevel 1   # รันซ้ำเพื่อดูว่า WAF ลดทอน payload ไปบ้าง
```

## หน้าเว็บสรุปผล

`New-Dashboard.ps1` อ่าน `evidence/results.json` ที่ตัวรันเขียนไว้ทุกรอบ
แล้วสร้าง `dashboard.html` ไฟล์เดียวจบ

```powershell
# รันเทสต์แล้วสร้างหน้าเว็บในคำสั่งเดียว
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence -Dashboard

# หรือสร้างใหม่จากผลรอบล่าสุดโดยไม่ต้องยิง request ซ้ำ
.\scripts\New-Dashboard.ps1
```

หน้าเว็บเปิดจาก `file://` ได้เลย ไม่ต้องมีเซิร์ฟเวอร์ ไม่ต้องมีเน็ต
และไม่ต้องติดตั้งอะไร เพราะข้อมูลถูกฝังไว้ในไฟล์ HTML ไม่ได้ดึงมาด้วย `fetch()`
ซึ่งเบราว์เซอร์จะบล็อกเมื่อเปิดแบบ `file://`

ในหน้าเว็บมีตัวกรองตามผลและตามไฟล์ ช่องค้นหา และคลิกที่แถวเพื่อดู URL
เหตุผลที่ไม่ผ่าน กับลิงก์ไปยังไฟล์หลักฐานใน `evidence/`
รหัสและชื่อเทสต์เป็นภาษาอังกฤษตามที่เขียนไว้ใน `http/*.http`
ส่วนข้อความอื่นเป็นภาษาไทย

ตรวจสอบว่าหน้าเว็บยังแสดงผลถูกต้องได้ด้วย (ถ้ามี Node.js ติดตั้งไว้):

```powershell
node .\scripts\Test-Dashboard.js     # ตรวจข้อมูล ตัวเลข และลิงก์หลักฐาน
node .\scripts\Test-DashboardUi.js   # ตรวจตัวกรองและช่องค้นหาในเบราว์เซอร์จริง
```

สคริปต์ทดสอบสองตัวนี้เป็นของ optional ตัวรันเทสต์หลักไม่ได้พึ่ง Node.js เลย

## หลักฐาน

`evidence/` มีไฟล์หนึ่งไฟล์ต่อหนึ่ง response ที่ตรวจสอบแล้ว (117 ไฟล์ ประมาณ 10 MB)
ตั้งชื่อตามชื่อเทสต์ แต่ละไฟล์มี request ที่ส่งและ response เต็ม ทำให้ตรวจสอบ
ผลการค้นพบซ้ำได้โดยไม่ต้องรันอะไรใหม่:

```powershell
Get-Content .\evidence\INFO-01_CRITICAL___admin__publishes_the_credentials_.txt -TotalCount 40
```

## ความปลอดภัย

image นี้เต็มไปด้วย RCE, SQL injection และ LFI ที่ไม่ต้องล็อกอินโดยเจตนา

- พอร์ตผูกกับ `127.0.0.1` เท่านั้น ห้าม publish ออกไป
- ไม่มี volume mount เด็ดขาด เพื่อไม่ให้ webshell ที่อัปโหลดหลุดออกมานอก container
- container ใช้แล้วทิ้งได้ `-Reset` คือการลบทิ้งทั้งตัว

## ภาษา

เอกสารและคอมเมนต์ในโค้ดเป็นภาษาไทย แต่ชื่อเทสต์ในไฟล์ `.http` คงเป็นภาษาอังกฤษ
โดยตั้งใจ เพราะ runner ใช้ชื่อเทสต์ไปสร้างชื่อไฟล์ใน `evidence/` และใช้เป็น
test id ในการกรองด้วย `-Only` ถ้าเป็นภาษาไทย ตัวกรอง
`[^A-Za-z0-9._-]` ใน `Run-HttpFile.ps1` จะแปลงอักขระทั้งหมดเป็น `_`
ทำให้ชื่อไฟล์อ่านไม่ออก
