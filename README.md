# project cyber - ห้องทดลองทดสอบความปลอดภัยเว็บ bWAPP อัตโนมัติ

ห้องทดลอง penetration testing ที่ทำซ้ำได้ สร้างได้เองทั้งหมด (self-contained) สำหรับ
[bWAPP](https://github.com/raesene/bWAPP) มีเทสต์เคส HTTP ทั้งหมด 122 กรณี
ซึ่งถูกส่งและตรวจสอบผลลัพธ์อัตโนมัติ พร้อมหลักฐานครบทุกข้อ

ทุกอย่างทำงานกับ container Docker แบบใช้แล้วทิ้ง บน `127.0.0.1:8443`
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

# 2. รันเทสต์ทั้งหมด บันทึก response แล้วสร้างหน้าเว็บสรุปผล
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence -Dashboard

# 3. เปิด dashboard.html ด้วยเบราว์เซอร์

# 4. เริ่มต้นใหม่ทั้งหมด
.\scripts\setup-bwapp.ps1 -Reset
```

`setup-bwapp.ps1` เป็นขั้นตอนเดียวที่จำเป็นจริง ๆ ขั้นตอนที่ 2 จะเข้าสู่ระบบเอง
และไม่ต้องตั้งค่าอะไรเพิ่ม

ถ้าชอบใช้ Compose: `docker compose up -d` แล้วรัน `setup-bwapp.ps1` โดยไม่ใส่
`-Reset` - ตรรกะการ seed เหมือนกันทุกประการ

## ส่ง request เองจาก VS Code (REST Client)

ตัวรัน PowerShell ไม่จำเป็น - ส่งด้วยมือในไฟล์ `http/*.http` ได้เช่นกัน

1. ติดตั้งส่วนขยาย **REST Client** (`humao.rest-client`)
2. เปิดโฟลเดอร์นี้เป็น workspace แล้วรัน `.\scripts\setup-bwapp.ps1` ให้เสร็จก่อน
   คำสั่งนี้จะเขียนตัวแปรที่ REST Client ใช้ลง `.vscode/settings.json` ให้เอง
3. เลือก **No Environment** ที่มุมบนขวาของหน้าต่าง REST Client
4. กด **Send** ที่คำขอในไฟล์ `.http`

### ทำไมตัวแปรต้องอยู่ใน .vscode/settings.json

REST Client **ไม่อ่านไฟล์ env ใด ๆ ทั้งสิ้น** - ไม่ใช่ `http-client.env`
ไม่ใช่ `.env` และไม่ไล่หาไฟล์จากโฟลเดอร์ไหนทั้งนั้น ตัวแปรที่มันรู้จักมีสามทางเท่านั้น

| ทาง | รูปแบบ | หมายเหตุ |
| --- | --- | --- |
| file variable | `@name = value` | ต้องประกาศ**ภายในไฟล์ `.http` ที่เปิดอยู่** เท่านั้น |
| system variable | `{{$dotenv x}}`, `{{$processEnv x}}` | อ่านไฟล์ชื่อ `.env` หรือ env ของ process |
| environment variable | `{{name}}` | อ่านจาก setting `rest-client.environmentVariables` |

ถ้าไม่มีทางใด ตัวแปรจะถูกทิ้งไว้เป็นข้อความ `{{baseUrl}}` ตรง ๆ ในบรรทัดคำขอ
URL จึงไม่มี host/port และทุกคำขอจะล้มด้วย `ECONNREFUSED` ข้อความแบบ
"The connection was rejected ... Details: RequestError" **ไม่ได้แปลว่า service ตาย**
แปลว่า REST Client แทนค่าไม่ได้และไปต่อที่ปลายทางผิดที่

`scripts/Set-RestClientVars.ps1` เป็นคนเขียนตัวแปรทั้งหมดลง `.vscode/settings.json`
ใต้คีย์ `$shared` ซึ่งอ่านได้แม้ไม่ต้องเลือก environment ใด ๆ (เลือก `No Environment`)
ทั้ง `setup-bwapp.ps1` และ `Run-HttpFile.ps1` เรียกฟังก์ชันนี้ทุกครั้งที่ล็อกอินใหม่
จึงไม่ต้องแก้ไฟล์ `.http` แม้แต่ไฟล์เดียว และ `.vscode/` อยู่ใน `.gitignore` โดยตั้งใจ
เพราะไฟล์นี้เก็บ `PHPSESSID` ที่ยังใช้งานได้

### เซสชันหมดอายุ

REST Client เข้าสู่ระบบให้เองไม่ได้ ต่างจาก `Run-HttpFile.ps1`
ถ้า `@authCookie` ใน `.vscode/settings.json` หมดอายุ ให้สั่ง
`.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -UpdateEnv` ซึ่งจะเขียนค่าใหม่ให้ทั้งสองไฟล์
(อย่ารันเฉพาะ `http\00-auth.http` เพราะไฟล์นั้นจบด้วย `logout.php` ซึ่งทำลาย session ทิ้ง)

## สิ่งที่สคริปต์ setup แก้ไข

image `raesene/bwapp:latest` สตาร์ตได้ แต่ถ้านำมาใช้ตามสภาพจะไม่ทำงาน:

| ปัญหา | สิ่งที่สคริปต์ทำ |
| --- | --- |
| MySQL สตาร์ต **ว่างเปล่า** - ทุกหน้าที่อ่านข้อมูลจะ error | อ่าน `/var/www/html/db/bwapp.sqlite` จากใน container แล้วเล่นซ้ำเข้า MySQL โดยแปลงทั้ง DDL และข้อมูล |
| SQLite ไม่มี `AUTO_INCREMENT` ทำให้ `blog.id` ไม่ถูกกำหนดค่าอัตโนมัติ และ INSERT ครั้งที่สองชนกันที่ `id 0` | คืน `AUTO_INCREMENT` ให้คอลัมน์ที่เป็น primary key แบบ integer คอลัมน์เดียว |
| ผู้ใช้ฐานข้อมูลของแอปมองไม่เห็นตารางที่ import มา | `GRANT ALL ON bWAPP.*` |
| `images/`, `documents/` และ `logs/` เป็น read-only สำหรับ `www-data` ทำให้ยืนยันช่องโหว่ file upload ไม่ได้ | `chmod 0777` ทั้งสามโฟลเดอร์ |
| ยังไม่มี session ที่ใช้ได้สำหรับชุดเทสต์ | เข้าสู่ระบบในชื่อ `bee`, ตรวจสอบ 302 แล้วเขียน `PHPSESSID` ที่ใช้งานได้ลงใน `http/http-client.env` |

สคริปต์เป็น idempotent: รันสองครั้ง ครั้งที่สองจะรายงานว่า `schema already present`
และไม่แก้อะไรเลย

## โครงสร้างโปรเจกต์

```
http/http-client.env        ตัวแปรร่วมสำหรับตัวรัน PowerShell ของโปรเจกต์นี้
                           (อยู่ใน .gitignore; http/http-client.env.example คือเทมเพลต
                           ที่ track ไว้) REST Client ไม่อ่านไฟล์นี้ - ดู .vscode/settings.json
.vscode/settings.json       ตัวแปรชุดเดียวกันสำหรับ VS Code REST Client อยู่ใต้คีย์
                           $shared (อยู่ใน .gitignore เพราะเก็บ PHPSESSID ที่ยังใช้ได้)
                           เขียนโดย scripts/Set-RestClientVars.ps1
http/*.http                ชุดเทสต์ - HTTP ล้วน ไม่พึ่งเฟรมเวิร์กใด
scripts/setup-bwapp.ps1    สร้างแล็บขึ้นมาจากศูนย์
scripts/Run-HttpFile.ps1   ตัว parse, ส่ง, ตรวจสอบ และสรุปผลของไฟล์ .http
scripts/Set-RestClientVars.ps1  เขียนตัวแปรลง .vscode/settings.json ให้ REST Client
scripts/validate.ps1       ตัวตรวจสอบแบบ batch รุ่นเก่า เก็บไว้เป็นมุมมองที่สอง
scripts/probe.ps1          ยิง request เดี่ยว ๆ ที่ล็อกอินแล้ว เอาไว้เดิ
scripts/New-Dashboard.ps1  สร้าง dashboard.html จากผลรอบล่าสุด
scripts/Test-Dashboard.js  ตรวจข้อมูลใน dashboard (ต้องมี Node.js)
scripts/Test-DashboardUi.js ตรวจพฤติกรรมตัวกรองในเบราว์เซอร์จริง (ต้องมี Node.js)
evidence/                  response ที่บันทึกไว้ (อยู่ใน .gitignore, ~10 MB)
dashboard.html             หน้าเว็บสรุปผล (อยู่ใน .gitignore, สร้างใหม่ได้เสมอ)
docs/report.md             รายงานช่องโหว่ทั้งหมด
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

ไฟล์นี้เป็นภาพ snapshot ของผลรอบล่าสุด ไม่ใช่ตัวรันเทสต์
และถูก `.gitignore` ไว้เช่นเดียวกับ `evidence/`
เพราะเนื้อหาขึ้นกับผลการรันจริงและมีขนาดระดับหลายสิบ KB

ตรวจสอบว่าหน้าเว็บยังแสดงผลถูกต้องได้ด้วย (ถ้ามี Node.js ติดตั้งไว้):

```powershell
node .\scripts\Test-Dashboard.js     # ตรวจข้อมูล ตัวเลข และลิงก์หลักฐาน
node .\scripts\Test-DashboardUi.js   # ตรวจตัวกรองและช่องค้นหาในเบราว์เซอร์จริง
```

สคริปต์ทดสอบสองตัวนี้เป็นของ optional ตัวรันเทสต์หลักไม่ได้พึ่ง Node.js เลย

## runner สองตัว

`Run-HttpFile.ps1` คือตัวหลัก มันอ่านไฟล์ `.http` เดิม ทำให้เทสต์ยังอ่านเข้าใจง่าย
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

- `### EXPECT-STATUS: 200` - status ที่คาดหวัง, `200|302` ได้เมื่อมีหลายค่า
- `### EXPECT-BODY: ข้อความย่อย` - ข้อความที่ต้อง **มี** อยู่ใน body
- `### EXPECT-NOT: ข้อความย่อย` - **negative control**: ข้อความที่ต้อง **ไม่** มี
- `### EXPECT-HEADER: ชื่อ header` - ส่วนหัวที่ต้องมีอยู่
- `### EXPECT-TIME-AT-LEAST: 500` - assertion ด้านเวลา ใช้กับ blind injection
- `### SKIP` - รายงานเคสนี้แต่ไม่ส่งคำขอ (นับเป็น planned)

รูปแบบข้อความธรรมดาสำหรับอ่านง่าย ใช้ได้กับ editor ที่ไม่เข้าใจ syntax ข้างบน
ตัว runner ดันจับให้บางส่วน:

```http
### Expected: 200, body contains "The movie exists in our database!"
```

คำเตือนสำคัญเรื่องความหมายของ PASS
: เคสที่ไม่มี `EXPECT-*` เลยจะเริ่มต้นเป็น `PASS` และจะกลายเป็น `FAIL`
  เฉพาะเมื่อได้ status >= 400 หรือถูกเด้งกลับ `login.php` (session หมด)
  ดังนั้นตัวเลข PASS ที่รายงานเป็นการยืนยันว่า**เป้าหมายตอบกลับและ session ยังใช้ได้**
  ไม่ใช่การยืนยันว่าช่องโหว่ทำงานจริง การยืนยันระดับเนื้อหาต้องมี `EXPECT-BODY`
  หรือ `EXPECT-NOT` ปัจจุบันมี 11 เคสจาก 122 ที่ตรวจระดับเนื้อหา อีก 1 เคสตรวจ
  ระดับเวลา (`CMDI-09` ยืนยัน blind command injection ด้วยค่าความต่าง 5008ms
  เทียบกับ 8ms ของเคสปกติ) ส่วนที่เหลืออีก 105 เคสตรวจระดับ status เป็นหลัก
  และเป็นงานรอบถัดไป

ข้อควรระวังเวลาเลือก marker
: marker ที่กว้างเกินไปจะผ่านโดยไม่ได้ยืนยันอะไร เช่น `bWAPP` ปรากฏใน 84 จาก
  117 ไฟล์หลักฐาน และ `Did you captured our GOLDEN packet?` เป็นข้อความในเทมเพลต
  ของหน้า `commandi.php` ไม่ใช่ผลลัพธ์ของคำสั่งที่ inject การยืนยัน oracle ของ
  blind injection ต้องใช้ `EXPECT-TIME-AT-LEAST` ไม่ใช่ค้นหาข้อความใน body

สวิตช์ที่ใช้บ่อย:

```powershell
-File 'http\*.http'     # glob, ไฟล์เดียว หรือหลายไฟล์
-Only 'SQLI-*'          # กรองตาม test id
-SaveEvidence           # เขียนทุก response ลง evidence/
-ShowBody               # แสดง body ของเคสที่ fail
-UpdateEnv              # เขียน session ที่ใช้งานได้กลับลง http/http-client.env
                        # (.vscode/settings.json ถูกเขียนให้ทุกรอบอยู่แล้ว ไม่ต้องใช้ flag นี้)
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

ครอบคลุม 122 เคส แบ่งตามกลุ่มช่องโหว่ได้ดังนี้

| กลุ่ม | เคส |
| --- | --- |
| Baseline / ตรวจความยังมีชีวิตของเป้าหมาย | 6 |
| SQL injection | 15 |
| XSS (reflected, stored, cookie, หลาย context) | 14 |
| Local file read และ source disclosure | 9 |
| OS command injection และ PHP code injection | 11 |
| XXE และ XML injection | 7 |
| Mail header injection | 2 |
| Unrestricted file upload | 4 |
| Authentication และ session | 15 |
| CSRF | 4 |
| Clickjacking | 2 |
| CORS | 3 |
| Information disclosure, open redirect, header injection | 19 |
| Host header และ HTTP verb | 6 |
| HTTP request smuggling | 3 |
| DoS | 2 |

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
Get-Content .\evidence\08-info-disclosure__INFO-01.txt -TotalCount 40
```

## ภาษา

เอกสาร คอมเมนต์ และหัวข้อของเทสต์ในไฟล์ `.http` เป็นภาษาไทย
รหัสเทสต์ (เช่น `SQLI-01` `INFO-08` `BOOT-02`) ยังคงเป็นตัวอักษรละติน
ตัวพิมพ์ใหญ่ต่อท้ายด้วยตัวเลข เพื่อให้กรองด้วย `-Only` ได้ และเพื่อให้
ชื่อไฟล์ใน `evidence/` อ่านได้ ตัวรันจะตัดรหัสนี้ออกมาจากหัวข้อแล้วใช้เป็น
ชื่อไฟล์หลักฐานรูปแบบ `<ไฟล์>__<รหัสเทสต์>.txt` เช่น
`08-info-disclosure__INFO-01.txt` หัวข้อภาษาไทยจึงไม่กระทบชื่อไฟล์

คำเหล่านี้ต้องคงเป็นภาษาอังกฤษ เพราะเป็นสัญญาระหว่างไฟล์กับตัวรัน:
`EXPECT-STATUS:` `EXPECT-BODY:` `EXPECT-NOT:` `EXPECT-HEADER:`
`EXPECT-TIME-AT-LEAST:` `SKIP` และ `Expected:` ขณะที่การยืนยันผลจากเนื้อหา
response เขียนได้ทั้งแบบไทย `body ต้องมี "..."` / `body ต้องไม่มี "..."`
และแบบอังกฤษ `body contains "..."` / `body must not contain "..."`
สตริงที่อยู่ในเครื่องหมายคำพูดต้องเป็นข้อความตามที่แอปตอบจริง ห้ามแปล
