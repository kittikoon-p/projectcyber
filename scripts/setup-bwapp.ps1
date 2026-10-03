<#
    .SYNOPSIS
        ยกชุด bWAPP แบบใช้แล้วทิ้งขึ้นมาใหม่ และเตรียมให้พร้อมสำหรับชุดเทสต์นี้

    .DESCRIPTION
        image raesene/bwapp มาพร้อมชุด PHP/Apache ที่ใช้งานได้จริง แต่ฐานข้อมูล
        MySQL ว่างเปล่า - แอปจะบูตได้ แต่ทุกหน้าที่อ่านข้อมูลจะล้มเหลว
        ข้อมูลตั้งต้นอยู่ที่ /var/www/html/db/bwapp.sqlite สคริปต์นี้จึงแปลง
        ไฟล์ SQLite นั้นเป็น schema ของ MySQL ที่แอปคาดไว้

        นอกจากนี้ยังทำให้โฟลเดอร์เป้าหมายการอัปโหลดเขียนได้ เพราะ image จัด images/
        และ documents/ ให้เป็นแบบอ่านอย่างเดียวสำหรับผู้ใช้ www-data ดังนั้นข้อค้นพบ
        เรื่องการอัปโหลดไฟล์ (UPL-01..04) จะสาธิตไม่ได้จนกว่าจะ chmod ให้แล้ว

        ทุกอย่างในสคริปต์นี้เป็นการทำลายข้อมูลภายใน container และไม่มีส่วนใด
        แตะต้อง host ลบ container แล้วรันใหม่เพื่อได้ lab ที่สะอาด

    .PARAMETER Port
        พอร์ตของ host ที่จะเปิดให้เข้าถึง ค่าเริ่มต้น 8443

    .PARAMETER Reset
        ลบและสร้าง container ที่มีอยู่ก่อน

    .EXAMPLE
        .\scripts\setup-bwapp.ps1
        .\scripts\setup-bwapp.ps1 -Port 9090 -Reset
#>
[CmdletBinding()]
param(
    [int]$Port = 8443,
    [string]$Container = 'bwapp',
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 writes to the console using the OEM code page, so Thai text in
# these messages turns into mojibake unless the console is switched to UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }


. (Join-Path $PSScriptRoot 'Set-RestClientVars.ps1')

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    ok: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }

# คำสั่ง native เขียนความคืบหน้าลง stderr ซึ่ง PowerShell 5.1 จะเปลี่ยนเป็น
# terminating error เมื่อ $ErrorActionPreference = 'Stop' เราจึงส่งผ่านฟังก์ชัน
# เหล่านี้ เพื่อให้ exit code ที่ไม่เป็นศูนย์กลายเป็นค่าที่คืน ไม่ใช่ exception
# ส่วนท้ายของ $args ถูกใช้โดยตั้งใจ: flag ของ docker เช่น -a / --filter จะถูก
# parameter binder ของ PowerShell กลืนไป หากส่งตรงๆ และเครื่องหมายคำพูดคู่ที่
# ฝังอยู่จะถูก PowerShell 5.1 ถอดออกจากอาร์กิวเมนต์ของคำสั่ง native - นั่นคือเหตุผล
# ที่ SQL ทั้งหมดถูกส่งผ่าน stdin แทนที่จะใช้ -e "..."
function Run-Native {
    param([string]$Exe)
    $ArgList = $args
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Exit = $code; Out = ($out -join "`n") }
}

# ส่ง SQL เข้าไปทาง stdin: ไม่ต้องหลีกเลี่ยงการใส่เครื่องหมายคำพูดของ shell
function Invoke-Mysql {
    param([string]$Sql, [switch]$NoHeader)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $mysqlArgs = @('exec', '-i', $Container, 'mysql', '-u', 'root')
        if ($NoHeader) { $mysqlArgs += '-N' }
        $out = $Sql | & docker @mysqlArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Exit = $code; Out = (($out | Where-Object { $_ -notmatch '^mysql: \[Warning\]' }) -join "`n") }
}

# ---------------------------------------------------------------- docker (เด็กเกอร์)
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "ไม่พบ docker ใน PATH - กรุณาติดตั้ง Docker Desktop ก่อน"
}
$daemon = Run-Native docker info
if ($daemon.Exit -ne 0) { throw "เข้าถึง docker daemon ไม่ได้ - กรุณาเปิด Docker Desktop แล้วลองใหม่" }

# ---------------------------------------------------------------- container (คอนเทนเนอร์)
$existing = (Run-Native docker ps -a --filter "name=^/$Container$" --format '{{.Names}}').Out
if ($existing -and $Reset) {
    Step "กำลังลบ container '$Container' ที่มีอยู่"
    Run-Native docker rm -f $Container *> $null
    $existing = ''
}
if (-not $existing) {
    Step "กำลังเริ่ม raesene/bwapp:latest เป็น '$Container' บน 127.0.0.1:$Port"
    $run = Run-Native docker run -d --name $Container -p "127.0.0.1:${Port}:80" raesene/bwapp:latest
    if ($run.Exit -ne 0) { throw "docker run ล้มเหลว:`n$($run.Out)" }
}

Step "กำลังรอให้ Apache ตอบที่ 127.0.0.1:$Port"
$ready = $false
$lastApacheError = ''
foreach ($i in 1..60) {
    Start-Sleep -Milliseconds 500
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port/login.php" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop *> $null
        $ready = $true; break
    } catch {
        $sc = $_.Exception.Response
        if ($sc) {
            # การตอบกลับ HTTP ใดๆ ก็แปลว่า Apache ขึ้นแล้ว; 302 คือการ redirect
            # ของ GET /login.php เมื่อ session หมดอายุ
            $ready = $true; break
        }
        $lastApacheError = $_.Exception.Message
        # "connection closed" / "state of the object" คือ client ของ
        # .NET/PowerShell ทำงานผิด ไม่ใช่ Apache ล้มเหลว จึงต้องไม่จบการรอ
    }
}
if (-not $ready) { throw "Apache ไม่ทำงาน ($lastApacheError) - ตรวจสอบ: docker logs $Container" }
Ok "login.php ตอบกลับแล้ว"

# ---------------------------------------------------------------- ฐานข้อมูล (database)
# MySQL จะถูก initialize เมื่อบูตครั้งแรก และยังไม่พร้อมใช้งานตอน Apache เริ่มตอบ
Step "กำลังรอ MySQL ใน container"
$dbReady = $false
foreach ($i in 1..60) {
    if ((Invoke-Mysql 'SELECT 1' -NoHeader).Exit -eq 0) { $dbReady = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $dbReady) { throw "MySQL ไม่พร้อมใช้งาน - ตรวจสอบ: docker logs $Container" }
Ok "MySQL รับการเชื่อมต่อแล้ว"

Step "กำลังตรวจสอบ schema ของ MySQL ใน bWAPP"
if ((Invoke-Mysql 'USE bWAPP; SELECT 1 FROM users LIMIT 1;' -NoHeader).Exit -eq 0) {
    Ok "มี schema อยู่แล้ว"
} else {
    Warn "ฐานข้อมูล bWAPP ว่างเปล่า (นี่คือสถานะปกติของ image ที่ให้มา) - กำลังนำเข้า"

    # SQLite เล่นซ้ำเข้า MySQL โดยตรงไม่ได้ จึงต้องแปลทั้ง DDL และแถวข้อมูล
    # แอปอ่านชื่อคอลัมน์เฉพาะจึงสร้างคำสั่ง CREATE TABLE จากไฟล์ตั้งต้น
    # แทนการเขียนขึ้นมาเอง
    $py = @'
import re, sqlite3
con = sqlite3.connect("/var/www/html/db/bwapp.sqlite")
cur = con.cursor()

def to_mysql(ddl):
    ddl = ddl.replace('"', "`")                      # "col" -> `col` (เครื่องหมายคำพูดคู่ -> backtick)
    ddl = re.sub(r"\bint\(\d+\)", "int(10)", ddl)   # sqlite int(N) -> mysql int(10)
    ddl = re.sub(r"\bAUTOINCREMENT\b", "AUTO_INCREMENT", ddl)
    # SQLite ไม่มี AUTO_INCREMENT - ใช้ rowid แบบโดยนัยแทน INSERT ของ bWAPP
    # ไม่เคยส่งค่า `id` มา ดังนั้น primary key แบบจำนวนเต็มคอลัมน์เดียวต้องเป็น
    # AUTO_INCREMENT ใน MySQL ไม่เช่นนั้นสอง INSERT แรกจะชนกันที่ id 0
    pk = re.search(r'PRIMARY KEY \(`(\w+)`\)', ddl)
    if pk and re.search(r'`%s`\s+int\(' % pk.group(1), ddl):
        ddl = ddl.replace('`%s` int(' % pk.group(1), '`%s` int(' % pk.group(1), 1)
        ddl = re.sub(r'(`%s`\s+int\([^)]*\))' % pk.group(1), r'\1 NOT NULL AUTO_INCREMENT', ddl, count=1)
    return ddl

out = ["CREATE DATABASE IF NOT EXISTS bWAPP;", "USE bWAPP;"]
tables = [t for (t,) in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()]

for t in tables:
    ddl = cur.execute("SELECT sql FROM sqlite_master WHERE name = ?", (t,)).fetchone()[0]
    out.append(to_mysql(ddl).strip() + ";")

for t in tables:
    cols = [r[1] for r in cur.execute("PRAGMA table_info(%s)" % t).fetchall()]
    rows = cur.execute("SELECT * FROM %s" % t).fetchall()
    if not rows:
        continue
    collist = ",".join("`%s`" % c for c in cols)
    for row in rows:
        vals = []
        for v in row:
            if v is None:
                vals.append("NULL")
            elif isinstance(v, (int, float)):
                vals.append(str(v))
            else:
                s = str(v).replace("\\", "\\\\").replace("'", "''")
                vals.append("'%s'" % s)
        out.append("INSERT INTO `%s` (%s) VALUES (%s);" % (t, collist, ",".join(vals)))

open("/tmp/seed.sql", "w").write("\n".join(out) + "\n")
print("tables: " + ", ".join(tables))
'@
    $pyFile = Join-Path $env:TEMP 'bwapp-seed.py'
    [System.IO.File]::WriteAllText($pyFile, ($py -replace "`r`n", "`n"))
    Run-Native docker cp $pyFile "${Container}:/tmp/bwapp-seed.py" *> $null

    # สร้าง SQL ภายใน container แล้วส่งกลับมาทาง pipe
    $gen = Run-Native docker exec $Container python3 /tmp/bwapp-seed.py
    if ($gen.Exit -ne 0) { throw "สร้างข้อมูลตั้งต้นไม่สำเร็จ:`n$($gen.Out)" }
    Ok "สร้างแล้ว: $($gen.Out)"
    $seed = Run-Native docker exec $Container cat /tmp/seed.sql
    if (-not $seed.Out.Trim()) { throw "ไฟล์ seed ว่างเปล่า - มี /var/www/html/db/bwapp.sqlite อยู่หรือไม่" }

    $import = Invoke-Mysql $seed.Out
    if ($import.Exit -ne 0) { throw "นำเข้าไม่สำเร็จ:`n$($import.Out)" }

    $users = (Invoke-Mysql 'USE bWAPP; SELECT COUNT(*) FROM users;' -NoHeader).Out
    if ($users -match '^\d+$' -and [int]$users -gt 0) { Ok "นำเข้าผู้ใช้แล้ว $users คน" }
    else { throw "การนำเข้าไม่ได้ผู้ใช้เลย (ได้: '$users')" }

    # การนำเข้าข้อมูลอีกหลายร้อยแถวอาจทำให้ MySQL ที่เพิ่งเริ่มทำงานล่ม
    # จึงต้องยืนยันว่ามันกลับมาแล้วก่อนอย่างอื่นมาแตะฐานข้อมูล
    Step "กำลังตรวจสอบ MySQL อีกครั้งหลังนำเข้า"
    $back = $false
    foreach ($i in 1..40) {
        if ((Invoke-Mysql 'SELECT 1' -NoHeader).Exit -eq 0) { $back = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $back) { throw "MySQL ไม่ฟื้นหลังจากการนำเข้า - ตรวจสอบ: docker logs $Container" }
    Ok "MySQL กลับมาทำงานแล้ว"
}

# แอปเชื่อมต่อด้วยบัญชี MySQL ของตัวเอง จึงต้องมีสิทธิ์ของตัวเองด้วย
$grant = Invoke-Mysql "GRANT ALL ON bWAPP.* TO 'bWAPP'@'localhost'; FLUSH PRIVILEGES;"
if ($grant.Exit -ne 0) { Warn "ให้สิทธิ์ไม่สำเร็จ: $($grant.Out)" } else { Ok "ให้สิทธิ์ bWAPP.* แก่ผู้ใช้ฐานข้อมูลของแอปแล้ว" }

$counts = Invoke-Mysql @'
USE bWAPP;
SELECT CONCAT('users=', (SELECT COUNT(*) FROM users),
              ' movies=', (SELECT COUNT(*) FROM movies),
              ' heroes=', (SELECT COUNT(*) FROM heroes),
              ' blog=',  (SELECT COUNT(*) FROM blog));
'@ -NoHeader
Ok "จำนวนแถว: $($counts.Out)"

# ---------------------------------------------------------------- สิทธิ์เขียน (writability)
# หากไม่ทำขั้นตอนนี้ เทสต์การอัปโหลดจะวางไฟล์ไม่ได้เลย เพราะ image ส่งมาโฟลเดอร์
# เหล่านี้โดยไม่มีสิทธิ์เขียนสำหรับ uid=33 (www-data)
Step "กำลังทำให้โฟลเดอร์เป้าหมายการอัปโหลดเขียนได้"
Run-Native docker exec $Container sh -c 'mkdir -p /app/logs && chmod 0777 /app/logs /app/images /app/documents' *> $null
$mode = Run-Native docker exec $Container sh -c 'stat -c %a:%n /app/images /app/documents /app/logs'
foreach ($line in ($mode.Out -split "`n" | Where-Object { $_ })) { Ok "chmod $line" }

# ---------------------------------------------------------------- ตรวจสอบ (sanity)
Step "กำลังยืนยันว่าข้อมูลเข้าสู่ระบบเริ่มต้นใช้ได้"
# หมายเหตุ: ใช้ Invoke-WebRequest ที่นี่ไม่ได้ PowerShell 5.1 จะ throw
# "Operation is not valid due to the current state of the object" เมื่อ
# -WebSession ถูกใช้ร่วมกับ -MaximumRedirection 0 ซึ่งเป็นสิ่งที่จำเป็น
# พอดีสำหรับการอ่านค่า session cookie จาก 302 ให้เรียก HttpWebRequest โดยตรง
# bWAPP ส่ง PHPSESSID สองค่าใน header เดียว (ก่อนและหลัง regenerate) ค่าที่
# regenerate ใหม่จะมาทีหลังและเป็นค่าที่ใช้ได้จริง
$sid = ''
$loginStatus = 0
$loginError = ''
foreach ($attempt in 1..8) {
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/login.php")
        $req.Method = 'POST'
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 15000
        $body = [System.Text.Encoding]::UTF8.GetBytes('login=bee&password=bug&security_level=0&form=submit')
        $req.ContentLength = $body.Length
        $stream = $req.GetRequestStream(); $stream.Write($body, 0, $body.Length); $stream.Close()
        $resp = $req.GetResponse()
        $loginStatus = [int]$resp.StatusCode
        foreach ($c in @("$($resp.Headers['Set-Cookie'])" -split ',')) {
            if ($c -match '^\s*(PHPSESSID)=([^;]+)') { $sid = $Matches[2] }   # ค่าสุดสุดได้ผล
        }
        $resp.Close()
        if ($loginStatus -eq 302 -and $sid) { break }
    } catch {
        $sid = ''
        $loginError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 750   # worker อาจยังกำลังตั้งต้วมาหลังจากนำเข้า
}
if ($loginStatus -eq 302 -and $sid) { Ok "การเข้าสู่ระบบได้ 302 -> portal.php พร้อม session ที่ใช้ได้" }
else { Warn "การเข้าสู่ระบบไม่คืน session ที่ใช้ได้ (สถานะ $loginStatus, '$loginError')" }

if ($sid) {
    Ok "PHPSESSID=$sid"
    $root = Split-Path $PSScriptRoot -Parent
    # ไฟล์ env อ่านได้ด้วยตัวรัน PowerShell ของโปรเจกต์นี้เท่านั้น REST Client
    # ไม่รู้จักไฟล์นี้ ตัวแปรจริง ๆ ต้องอยู่ใน .vscode/settings.json (ดู Set-RestClientVars.ps1)
    $envFile = Join-Path $root 'http\http-client.env'
    # ไฟล์นี้อยู่ใน .gitignore จึงไม่มีมาใน clone ใหม่ ถ้ายังไม่มีต้องสร้างจากเทมเพลตก่อน
    if (-not (Test-Path $envFile)) {
        $envExample = Join-Path $root 'http\http-client.env.example'
        if (Test-Path $envExample) {
            Copy-Item $envExample $envFile
            Ok "สร้าง http\http-client.env จากเทมเพลตแล้ว"
        }
    }
    if (Test-Path $envFile) {
        $text = Get-Content $EnvFile -Encoding UTF8
        $text = $text -replace '(?m)^@baseUrl\s*=.*$', "@baseUrl = http://127.0.0.1:$Port"
        $text = $text -replace '(?m)^@session\s*=.*$', "@session = $sid"
        $text = $text -replace '(?m)^@authCookie\s*=.*$', "@authCookie = PHPSESSID=$sid; security_level=0"
        [System.IO.File]::WriteAllText($envFile, ($text -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Ok "เขียน session ที่ใช้งานได้ลงใน http\http-client.env แล้ว"
    }
} else { Warn "ไม่พบ PHPSESSID ที่ใช้ได้ - ให้รันชุดเทสต์และส่ง -UpdateEnv เพื่อรีเฟรชค่า" }

# REST Client อ่านตัวแปรจาก .vscode/settings.json เท่านั้น ต้องเขียนทุกครั้งที่ล็อกอินใหม่
# ตัวแปรที่เหลือมาจากค่าเริ่มต้นของ bWAPP ไม่ต้องอ่านจากไฟล์ env ก็ได้
$rcFile = Set-RestClientVars -Root (Split-Path $PSScriptRoot -Parent) -Vars @{
    baseUrl       = "http://127.0.0.1:$Port"
    session       = $sid
    authCookie    = "PHPSESSID=$sid; security_level=0"
    securityLevel = '0'
    bwappUser     = 'bee'
    bwappPass     = 'bug'
    beeHash       = '6885858486f31043e5839c735d99457f045affd0'
}
Ok "เขียนตัวแปรสำหรับ REST Client ลงใน $([System.IO.Path]::GetFileName($rcFile)) แล้ว (เลือก No Environment)"

# ---------------------------------------------------------------- สรุปผล (summary)
$hash = ''
foreach ($i in 1..10) {
    $r = Invoke-Mysql "USE bWAPP; SELECT password FROM users WHERE login = 'bee';" -NoHeader
    if ($r.Exit -eq 0 -and $r.Out -match '^[0-9a-f]{40}$') { $hash = $r.Out; break }
    Start-Sleep -Milliseconds 500
}
if (-not $hash) { Warn "อ่าน hash ของรหัสผ่านที่เก็บไว้กลับมาจาก MySQL ไม่ได้" }
Write-Host ""
Write-Host "  bWAPP พร้อมใช้งานที่  http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "  ข้อมูลเข้าสู่ระบบ   bee / bug   (SHA1 ที่เก็บไว้: $(if ($hash) { $hash } else { 'ไม่มีข้อมูล' }))" -ForegroundColor Gray
Write-Host "  รันชุดเทสต์        .\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence -UpdateEnv" -ForegroundColor Gray
Write-Host "  ส่งจาก VS Code      เปิดโฟลเดอร์นี้เป็น workspace แล้วเลือก No Environment ที่มุมบนขวา" -ForegroundColor Gray
Write-Host "  เริ่มต้นใหม่        .\scripts\setup-bwapp.ps1 -Reset" -ForegroundColor Gray
Write-Host ""