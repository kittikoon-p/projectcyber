<#
    .SYNOPSIS
        รันและตรวจสอบไฟล์คำขอใน http/*.http โดยไม่ต้องใช้ IDE

    .DESCRIPTION
        ตัวอ่าน (parser) และตัวส่ง (sender) สำหรับรูปแบบไฟล์ของ VS Code REST Client / JetBrains HTTP Client

        ไวยากรณ์ของคำขอ
            ###                     ความคิดเห็น / ชื่อคำขอ
            # comment               ความคิดเห็น
            @name = value           การกำหนดค่าตัวแปร (http-client.env)
            GET /path HTTP/1.1      บรรทัดคำขอ
            Header: value           ส่วนหัวของคำขอ
            <blank line>            จุดสิ้นสุดส่วนหัว จากนี้เป็นเนื้อหา (body) ตามที่เขียนไว้

        ข้อกำหนดการตรวจสอบ อ่านจากบล็อก ### ที่อยู่เหนือคำขอ
            ### EXPECT-STATUS: 200            สถานะที่ต้องตรงทั้งหมด
            ### EXPECT-STATUS: 200|302        สถานะที่ยอมรับได้ หนึ่งในหลายค่า
            ### EXPECT-BODY: some substring    ข้อความย่อยที่ต้องปรากฏ
            ### EXPECT-NOT: some substring     ข้อความย่อยที่ต้องไม่ปรากฏ
            ### EXPECT-HEADER: Name            ส่วนหัวการตอบกลับที่ต้องมีอยู่
            ### SKIP                            รายงานเคสนี้แต่ไม่ส่งคำขอ

        คำขอที่ไม่มีข้อกำหนดการตรวจสอบ จะถูกส่งและรายงานผลเท่านั้น ไม่ถือว่าล้มเหลว

        การจัดการ session
        ไฟล์ 00-auth.http จะเข้าสู่ระบบ และค่า Set-Cookie ที่ได้จะเติมที่เก็บคุกกี้ (cookie jar)
        ภายในรอบการรัน ดังนั้นไฟล์ที่เหลือจึงสืบทอด session ที่ยืนยันตัวตนแล้วโดยไม่ต้องคัดลอกเอง
        PHPSESSID ที่เรียนรู้ระหว่างรันจะเขียนทับค่า {{session}} ต่อไปในรอบการรันด้วย
        ซึ่งเป็นสิ่งที่ป้องกันไม่ให้ส่วนหัว Cookie: ที่ค้างอยู่จาก http-client.env
        มาทับ session ใหม่

    ไฟล์ผลลัพธ์
        ทุกรอบจะเขียน evidence/results.json เสมอ และเก็บหลักฐานแบบ .txt เมื่อใช้ -SaveEvidence
        สคริปต์ New-Dashboard.ps1 อ่าน results.json ไปสร้าง dashboard.html ซึ่งเปิดจาก file:// ได้
        ถ้ารันครบทุกไฟล์ ระบบจะลบหลักฐาน .txt เก่าที่ไม่อยู่ในผลรอบนี้ทิ้ง
        (ใช้ -KeepStaleEvidence เพื่อเก็บไว้ทั้งหมด)

    .EXAMPLE
        .\scripts\Run-HttpFile.ps1 -File http\00-auth.http
        .\scripts\Run-HttpFile.ps1 -File http\01-sqli.http -Only SQLI-03
        # รันทั้งหมด บันทึก response และอัปเดต @session สำหรับ IDE
        .\scripts\Run-HttpFile.ps1 -File http\*.http -SaveEvidence -UpdateEnv
        # รันทั้งหมดแล้วสร้างหน้าเว็บสรุปผลให้ด้วย
        .\scripts\Run-HttpFile.ps1 -File http\*.http -SaveEvidence -Dashboard
        # รายงานอย่างเดียว
        .\scripts\Run-HttpFile.ps1 -File http\*.http -ReportOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$File,
    [string]$EnvFile,
    [string]$Only,
    [switch]$SaveEvidence,
    [switch]$ShowBody,
    [switch]$UpdateEnv,
    [switch]$ReportOnly,
    [switch]$NoAutoLogin,
    [switch]$KeepStaleEvidence,
    [switch]$Dashboard
)

$ErrorActionPreference = 'Continue'

# PowerShell 5.1 writes to the console using the OEM code page, so Thai text in
# these messages turns into mojibake unless the console is switched to UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path $PSScriptRoot -Parent
# ไฟล์ env ของโปรเจกต์นี้ ตัวรันอ่านเอง แต่ REST Client อ่านไม่ได้ - ตัวแปรสำหรับ
# VS Code อยู่ใน .vscode/settings.json ซึ่ง Set-RestClientVars.ps1 เป็นคนเขียน
if (-not $EnvFile) { $EnvFile = Join-Path $Root 'http\http-client.env' }
. (Join-Path $PSScriptRoot 'Set-RestClientVars.ps1')
$AutoLogin = -not $NoAutoLogin

# ---------------------------------------------------------------- ตัวแปร
# ค่าเริ่มต้นมาก่อน เพื่อให้การ clone ใหม่ทำงานได้แม้ไม่มีไฟล์ http-client.env เลย
# ส่วนที่ไฟล์ env เป็นตัวกำหนดจะมีผลเหนือกว่า
$defaults = @{
    baseUrl       = 'http://127.0.0.1:8443'
    bwappUser     = 'bee'
    bwappPass     = 'bug'
    securityLevel = '0'
    beeHash       = '6885858486f31043e5839c735d99457f045affd0'
    session       = ''
    authCookie    = ''
}
$vars = @{} + $defaults
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile -Encoding UTF8) {
        if ($line -match '^\s*@(\w+)\s*=\s*(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim() }
    }
}
# ค่าว่างในไฟล์ env ไม่ควรลบค่าเริ่มต้นที่ใช้ได้อยู่
foreach ($k in $defaults.Keys) {
    if ([string]::IsNullOrWhiteSpace([string]$vars[$k])) { $vars[$k] = $defaults[$k] }
}

function Expand-Vars([string]$text) {
    if ($null -eq $text) { return $text }
    foreach ($k in @($vars.Keys)) {
        $text = $text.Replace("{{$k}}", [string]$vars[$k])
    }
    $text
}

# ---------------------------------------------------------------- ที่เก็บคุกกี้ (cookie jar)
$jar = @{}

function Read-CookiePairs([string]$header) {
    $pairs = [ordered]@{}
    if (-not $header) { return $pairs }
    foreach ($c in ($header -split ';')) {
        if ($c -match '^\s*([^=]+?)\s*=\s*(.*)$') { $pairs[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    $pairs
}

function Merge-CookieHeader([string]$explicit) {
    # ค่าที่ระบุไว้ในไฟล์มีผลเหนือกว่า jar จะเติมเฉพาะช่องที่ยังว่าง
    $pairs = Read-CookiePairs $explicit
    foreach ($k in $jar.Keys) {
        if (-not $pairs.Contains($k)) { $pairs[$k] = $jar[$k] }
    }
    if ($pairs.Count -eq 0) { return $null }
    (($pairs.Keys | ForEach-Object { "$_=$($pairs[$_])" }) -join '; ')
}

function Update-CookieJar($respHeaders) {
    $raw = $respHeaders['Set-Cookie']
    if (-not $raw) { return }
    foreach ($c in @($raw -split ',')) {
        if ($c -notmatch '^\s*([^=]+)=([^;]*)') { continue }
        $name = $Matches[1].Trim(); $val = $Matches[2].Trim()
        if ($val -eq '' -or $c -match 'Expires=Thu,\s*01-Jan-1970') { $jar.Remove($name) }
        else { $jar[$name] = $val }
    }
}

# ---------------------------------------------------------------- ตัวส่ง
function Send-Request {
    param([string]$Url, [string]$Method, [hashtable]$Headers, [string]$Body)

    $target = $Url -replace '^\w+://', ''
    $parts = $target -split '/', 2
    $hostPart = $parts[0]
    $path = if ($parts.Count -gt 1) { '/' + $parts[1] } else { '/' }

    $req = [System.Net.HttpWebRequest]::Create("http://$hostPart$path")
    $req.Method = $Method
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'bwapp-http-runner/1.0'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000

    $explicitCookie = $null
    foreach ($k in $Headers.Keys) {
        if ($k -ieq 'Content-Length') { continue }
        if ($k -ieq 'Cookie') { $explicitCookie = $Headers[$k]; continue }
        if ($k -ieq 'Content-Type') { $req.ContentType = $Headers[$k]; continue }
        if ($k -ieq 'Host') {
            # HttpWebRequest ปฏิเสธ Host ที่เท่ากับ authority ของ URI และจะ
            # อนุญาตให้กำหนดค่าใหม่ก็ต่อเมื่อค่านั้นต่างออกไป (จำเป็นสำหรับเทสต์ host-header)
            if ($Headers[$k] -ne $hostPart) { $req.Host = $Headers[$k] }
            continue
        }
        try { $req.Headers[$k] = $Headers[$k] } catch { Write-Verbose "ตัดหัวทิ้ง: $k" }
    }
    $ck = Merge-CookieHeader $explicitCookie
    if ($ck) { $req.Headers.Add('Cookie', $ck) }

    if ($Body -and -not [string]::IsNullOrWhiteSpace($Body)) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $b.Length
        $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) {
            $sw.Stop()
            return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message; Headers = @{}; Location = ''; Ms = $sw.ElapsedMilliseconds }
        }
    }
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $text = $sr.ReadToEnd(); $sr.Close()
    $sw.Stop()

    $hdr = @{}
    foreach ($k in $resp.Headers.AllKeys) { $hdr[$k] = $resp.Headers[$k] }
    Update-CookieJar $hdr

    [pscustomobject]@{
        Status   = [int]$resp.StatusCode
        Body     = $text
        Headers  = $hdr
        Location = $resp.Headers['Location']
        Ms       = $sw.ElapsedMilliseconds
    }
}

# ---------------------------------------------------------------- ตัวอ่าน
function New-Want {
    [ordered]@{ Status = $null; Body = @(); Not = @(); Header = @(); Skip = $false; Time = $null }
}

# หนึ่งบรรทัดข้อกำหนด -> หนึ่ง assertion รองรับทั้งรูปแบบสำหรับเครื่อง
#   EXPECT-STATUS: 200|302 / EXPECT-BODY: x / EXPECT-NOT: x / EXPECT-HEADER: x
# และรูปแบบข้อความธรรมดาที่ชุดเทสต์เขียนไว้ เช่น
#   Expected: 200, body contains "marker"
#   Expected: 200, body ต้องมี "marker"      (รูปแบบไทยที่ไฟล์ชุดเทสต์นี้ใช้)
function Add-Hint($want, [string]$text) {
    if ($text -match '^EXPECT-STATUS:\s*(\S+)') { $want.Status = @($Matches[1] -split '\|'); return }
    if ($text -match '^EXPECT-BODY:\s*(.+)$') { $want.Body += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-NOT:\s*(.+)$') { $want.Not += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-HEADER:\s*(.+)$') { $want.Header += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-TIME-AT-LEAST:\s*(\d+)') { $want.Time = [int]$Matches[1]; return }
    if ($text -match '^SKIP\b') { $want.Skip = $true; return }
    # สำรองสำหรับรูปแบบข้อความ: ห้ามเขียนทับบรรทัด EXPECT-* ที่ระบุชัดเจนในฟิลด์เดียวกัน
    if ($text -match 'Expected:\s*(\d{3})' -and -not $want.Status) { $want.Status = @($Matches[1]) }
    # รูปแบบข้อความภาษาไทยที่ไฟล์ชุดเทสต์นี้ใช้: body ต้องมี "..." / body ต้องไม่มี "..."
    # ต้องอยู่ก่อนรูปแบบอังกฤษ เพราะทั้งสองรูปแบบใช้เครื่องหมายคำพูดเหมือนกัน
    if ($text -match 'body ต้องไม่มี\s+"([^"]+)"') { $want.Not += $Matches[1]; return }
    if ($text -match 'body ต้องมี\s+"([^"]+)"') { $want.Body += $Matches[1]; return }
    # รูปแบบข้อความอังกฤษ ยังรองรับไว้เผื่อไฟล์เก่า
    if ($text -match 'body (?:must )?contains\s+"([^"]+)"') { $want.Body += $Matches[1] }
    if ($text -match 'body must not contain\s+"([^"]+)"') { $want.Not += $Matches[1] }
}

function Test-HintLine([string]$text) {
    $text -match '^(EXPECT-|SKIP\b|Expected:)'
}

function Read-HttpFile {
    param([string]$Path)

    $requests = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $cur = $null
    $mode = $null

    # -Encoding UTF8 บังคับให้อ่านเป็น UTF-8 ไม่งั้นคำอธิบายภาษาไทยในไฟล์ .http
    # จะกลายเป็นตัวอักษรมั่ว เพราะ PowerShell 5.1 ตอนไม่ระบุ encoding
    # จะใช้ code page ของระบบ (cp874 บนเครื่องไทย)
    foreach ($raw in Get-Content $Path -Encoding UTF8) {
        $line = $raw

        if ($line -match '^\s*###') {
            $text = ($line -replace '^\s*###+\s*', '').Trim()
            # บรรทัดข้อกำหนดที่อยู่ถัดจากคำขอเป็นเอกสารอธิบายคำขอนั้น จึงต้องไม่ปิดบล็อกของมัน
            # บรรทัดอื่นทั้งหมดจะเริ่มหรือต่อยอดบล็อกของคำขอถัดไป
            if ($cur -and (Test-HintLine $text)) {
                Add-Hint $cur.Want $text
                [void]$cur.Notes.Add($text)
                continue
            }
            if ($cur) { [void]$requests.Add($cur); $cur = $null; $mode = $null }
            if ($text -and $text -notmatch '^[-=~_*]{3,}$') { [void]$notes.Add($text) }
            continue
        }
        if ($line -match '^\s*#' -and -not $cur) { continue }

        if ($cur) {
            if ($mode -eq 'body') {
                $cur.Body += $line + "`n"
            } else {
                if ([string]::IsNullOrWhiteSpace($line)) { $mode = 'body'; continue }
                if ($line -match '^\s*([^:]+):\s*(.*)$') { $cur.Headers[$Matches[1].Trim()] = $Matches[2].Trim() }
            }
            continue
        }

        if ($line -match '^\s*([A-Z]+)\s+(\S.*?)(?:\s+HTTP/\d\.\d)?\s*$') {
            # แกนค่าออกจาก $Matches ทันที เพราะ -match ครั้งถัดไปจะเขียนทับมัน
            $mMethod = $Matches[1]
            $mUrl = $Matches[2]
            $noteSnapshot = @($notes)
            # -cmatch: รูปแบบ ID เป็นตัวพิมพ์ใหญ่ทั้งหมด ชื่อไฟล์ตัวพิมพ์เล็กใน
            # บล็อกความคิดเห็น (xxe-2.php, sqli_16.php) จึงต้องไม่ถูกเข้าใจผิดว่าเป็น ID
            $id = ($noteSnapshot | Where-Object { $_ -cmatch '^[A-Z]{2,}-\d+' } | Select-Object -First 1)
            $want = New-Want
            foreach ($n in $noteSnapshot) { Add-Hint $want $n }
            # เหตุผลของเคส PLANNED อยู่ในบรรทัดคำอธิบายก่อน request
            # ตัดบรรทัด ID และบรรทัดที่เป็น directive (EXPECT-*/SKIP) ออก
            $why = @($noteSnapshot | Where-Object {
                $_ -and $_ -ne $id -and -not (Test-HintLine $_)
            })
            $cur = [pscustomobject]@{
                Id      = if ($id) { $id } else { ($noteSnapshot | Select-Object -First 1) }
                Notes   = New-Object System.Collections.ArrayList
                Method  = $mMethod
                Url     = $mUrl.Trim()
                Headers = @{}
                Body    = ''
                Want    = $want
                Why     = $why
            }
            $notes.Clear()
            $mode = 'headers'
        }
    }
    if ($cur) { [void]$requests.Add($cur) }
    # ไม่เช่นนั้นบรรทัดว่างระหว่างบล็อกจะสะสมเข้าไปใน body ทำให้
    # HttpWebRequest ปฏิเสธ GET ด้วยข้อความ "cannot send a content-body with this verb"
    foreach ($q in $requests) { if ($q.Body) { $q.Body = ($q.Body -replace '(\r?\n)+$', '') } }
    , $requests
}

# bWAPP เรียก session_regenerate_id() และ logout.php ทำลาย session ทิ้งไปทั้งหมด
# ดังนั้นการรันข้ามหลายไฟล์จึงต้องเข้าสู่ระบบใหม่ระหว่างแต่ละไฟล์
# ข้อมูลเข้าสู่ระบบมาจาก http-client.env (@bwappUser / @bwappPass / @securityLevel)
function Login-Bwapp {
    $body = 'login={0}&password={1}&security_level={2}&form=submit' -f `
        [uri]::EscapeDataString($vars['bwappUser']), `
        [uri]::EscapeDataString($vars['bwappPass']), `
        [uri]::EscapeDataString($vars['securityLevel'])
    $res = Send-Request -Url "$($vars['baseUrl'])/login.php" -Method POST `
        -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } -Body $body
    if ($res.Status -eq 302 -and $res.Location -match 'portal|index') {
        if ($jar.ContainsKey('PHPSESSID') -and $jar['PHPSESSID']) {
            $script:liveSession = $jar['PHPSESSID']
            $vars['session'] = $liveSession
            $vars['authCookie'] = "PHPSESSID=$liveSession; security_level=0"
        }
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- การรัน
$results = New-Object System.Collections.ArrayList
$evidenceDir = Join-Path $Root 'evidence'
$liveSession = $null
if ($SaveEvidence -and -not $ReportOnly) { New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null }

foreach ($f in $File) {
    # ขยาย "http\*.http" - PowerShell ไม่ทำ glob ให้กับอาร์กิวเมนต์พาธที่อยู่ในเครื่องหมายคำพูด
    $matches = if ($f -match '[\*\?]') {
        @(Get-ChildItem -Path $f -File -ErrorAction SilentlyContinue | Sort-Object Name)
    } else { @($f) }
    if (-not $matches.Count) { Write-Output "!! ไม่พบไฟล์ที่ตรงกับ: $f"; continue }

    foreach ($f in $matches) {
    $full = if ([System.IO.Path]::IsPathRooted($f)) { "$f" } else { Join-Path $Root "$f" }
    if (-not (Test-Path $full)) { Write-Output "!! ไม่พบไฟล์: $f"; continue }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
    Write-Output ""
    Write-Output ("=" * 100)
    Write-Output "  $name.http"
    Write-Output ("=" * 100)

    # 00-auth.http เป็นตัวอย่างการเข้าสู่ระบบ จึงไม่ต้องแตะต้อง
    if ($AutoLogin -and $name -ne '00-auth' -and -not $ReportOnly) {
        if (Login-Bwapp) { Write-Output "  (เข้าสู่ระบบใหม่แล้วในชื่อ $($vars['bwappUser']))" }
        else { Write-Output "  !! auto-login FAILED - ผลลัพธ์ด้านล่างจะยังไม่ได้เข้าสู่ระบบ" }
    }

    $reqs = Read-HttpFile -Path $full
    $n = 0
    foreach ($r in $reqs) {
        $n++
        $id = if ($r.Id) { "$($r.Id)" } else { "$name-$n" }
        $id = ($id -replace '\s+', ' ').Trim()
        if ($id.Length -gt 52) { $id = $id.Substring(0, 52) }
        # รหัสเทสต์สั้น ๆ (เช่น SQLI-01) ใช้เป็นชื่อไฟล์หลักฐาน เพื่อให้ชื่อไฟล์ไม่ผูกกับภาษาของหัวข้อ
        $code = if ($id -cmatch '^([A-Z]{2,}-\d+)') { $Matches[1] } else { "$name-$n" }
        if ($Only -and $id -notmatch $Only) { continue }

        $headers = @{}
        foreach ($k in $r.Headers.Keys) { $headers[$k] = Expand-Vars $r.Headers[$k] }
        $url = Expand-Vars $r.Url
        $body = Expand-Vars $r.Body
        if ($url -match '\{\{' -or ($body -match '\{\{')) {
            Write-Output ("  {0,-9} {1,-52} SKIP (ตัวแปรยังไม่ถูกแทนค่า)" -f 'UNRESOLVED', $id)
            [void]$results.Add([pscustomobject]@{
                File = $name; Id = $id; Method = $r.Method; Url = $url; Status = '-'
                Bytes = 0; Ms = 0; Verdict = 'SKIP'; Reason = 'ตัวแปรยังไม่ถูกแทนค่า'
                Note = 'ตัวแปรยังไม่ถูกแทนค่า'; Evidence = ''
            })
            continue
        }
        if ($r.Want.Skip -or $ReportOnly) {
            Write-Output ("  {0,-9} {1,-52} {2} {3}" -f 'PLANNED', $id, $r.Method, $url)
            # บรรทัด RUNNER-CANNOT-SEND คือเหตุผลสั้นที่สุดที่เขียนไว้ในไฟล์ .http
            # เก็บทั้งเหตุผลยาวไว้ใน Note และเหตุผลสั้นไว้ใน Reason
            $short = (@($r.Why) | Where-Object { $_ -match '^\s*RUNNER-CANNOT-SEND' } | Select-Object -First 1)
            if (-not $short) { $short = @($r.Why)[0] }
            [void]$results.Add([pscustomobject]@{
                File = $name; Id = $id; Method = $r.Method; Url = $url; Status = '-'
                Bytes = 0; Ms = 0; Verdict = 'PLANNED'
                Reason = ($short -replace '^\s*RUNNER-CANNOT-SEND:\s*', '')
                Note = (@($r.Why) -join "\n"); Evidence = ''
            })
            continue
        }

        # 00-auth.http จบด้วย logout.php ซึ่งจะล้าง jar เราจึงใส่ session กลับเข้าไป
        # เพื่อให้การรันที่เหลือยังคงอยู่ในสถานะเข้าสู่ระบบแล้ว
        if ($liveSession -and -not $jar.ContainsKey('PHPSESSID')) { $jar['PHPSESSID'] = $liveSession }

        $res = Send-Request -Url $url -Method $r.Method -Headers $headers -Body $body
        if ($jar.ContainsKey('PHPSESSID') -and $jar['PHPSESSID']) {
            $liveSession = $jar['PHPSESSID']
            # ปรับ {{session}} ให้ตรงกับ session ที่ใช้งานจริง มิฉะนั้นส่วนหัว
            # Cookie: {{session}} ที่ค้างอยู่ในไฟล์ถัดไปจะมีผลเหนือ jar
            $vars['session'] = $liveSession
            $vars['authCookie'] = "PHPSESSID=$liveSession; security_level=0"
        }

        # ---- assertions (การตรวจสอบ)
        $verdict = 'PASS'
        $why = @()
        if ($r.Want.Status) {
            if ($res.Status -notin $r.Want.Status) { $verdict = 'FAIL'; $why += "status $($res.Status) ไม่อยู่ใน $($r.Want.Status -join '|')" }
        }
        # ข้อบังคับระดับทั้งหมด: ทุกอย่างนอกจาก endpoint ของ login/logout ต้องมี session ที่ใช้ได้จริง
        # การถูกส่งกลับไปที่ login.php เสมอแปลว่า session หมดอายุ
        if ($url -notmatch '/(login|logout|security_level_set)\.php' -and
            $res.Status -eq 302 -and $res.Location -match 'login\.php') {
            $verdict = 'FAIL'; $why += 'ถูกส่งกลับไปที่ login.php - session ยังไม่ได้เข้าสู่ระบบ'
        }
        foreach ($b in $r.Want.Body) {
            if ($res.Body -notlike "*$b*") { $verdict = 'FAIL'; $why += "body ไม่พบ '$b'" }
        }
        foreach ($b in $r.Want.Not) {
            if ($res.Body -like "*$b*") { $verdict = 'FAIL'; $why += "body ต้องไม่มี '$b'" }
        }
        foreach ($h in $r.Want.Header) {
            $found = $false
            foreach ($k in $res.Headers.Keys) { if ($k -ieq $h -or $res.Headers[$k] -like "*$h*") { $found = $true; break } }
            if (-not $found) { $verdict = 'FAIL'; $why += "header ไม่พบ '$h'" }
        }
        if ($r.Want.Time -and $res.Ms -lt $r.Want.Time) {
            $verdict = 'FAIL'; $why += "ใช้เวลา $($res.Ms)ms, คาดว่า >= $($r.Want.Time)ms"
        }
        # คำขอที่ไม่ได้อยู่ในช่วง 2xx และไม่มีข้อกำหนดที่ระบุไว้ ถือว่าไม่ผ่าน
        if (-not $r.Want.Status -and $res.Status -ge 400) { $verdict = 'FAIL'; $why += "ไม่คาดหวัง $($res.Status)" }

        $loc = if ($res.Location) { " -> $($res.Location)" } else { '' }
        $note = if ($why) { '  [' + ($why -join '; ') + ']' } else { '' }
        Write-Output ("  {0,-9} {1,-52} {2} {3} {4} bytes {5}ms{6}{7}" -f `
            $verdict, $id, $r.Method, ($url -replace [regex]::Escape($vars['baseUrl']), ''), $res.Body.Length, $res.Ms, $loc, $note)

        # ชื่อไฟล์หลักฐานถูกคำนวณก่อนบันทึกผล เพื่อให้ dashboard ผูกไปยังไฟล์เดียวกันได้
        # ใช้รหัสเทสต์เป็นชื่อไฟล์ ไม่ใช้หัวข้อ เพราะหัวข้อเป็นภาษาไทยแล้ว
        # การกรองอักษรที่ไม่ใช่ ASCII จะทำให้ได้ชื่ออย่าง INFO-01______________ ซึ่งอ่านยาก
        $evidenceName = "$($name)__$code.txt"

        [void]$results.Add([pscustomobject]@{
            File = $name; Id = $id; Method = $r.Method; Url = $url; Status = $res.Status
            Bytes = $res.Body.Length; Ms = $res.Ms; Verdict = $verdict
            Reason = ''; Note = ($why -join '; '); Evidence = $evidenceName
        })

        if ($SaveEvidence) {
            $dest = Join-Path $evidenceDir $evidenceName
            $hdrLines = ($res.Headers.Keys | Sort-Object | ForEach-Object { "$_`: $($res.Headers[$_])" }) -join "`n"
            @("$id", "$($r.Method) $url", "HTTP $($res.Status)  ($($res.Ms) ms)", "", "--- response headers (ส่วนหัวการตอบกลับ) ---", $hdrLines, "", "--- body (เนื้อหา) ---", $res.Body) |
                Out-File -Encoding utf8 $dest
        }
        if ($ShowBody) {
            Write-Output '      --- body (1500 ตัวอักษรแรก) ---'
            $snippet = if ($res.Body.Length -gt 1500) { $res.Body.Substring(0, 1500) } else { $res.Body }
            Write-Output ($snippet -split "`n" | ForEach-Object { "      $_" })
        }
    }
    }
}

# ---------------------------------------------------------------- สรุปผล
Write-Output ""
Write-Output ("=" * 100)
$pass = @($results | Where-Object Verdict -eq 'PASS').Count
$fail = @($results | Where-Object Verdict -eq 'FAIL').Count
$skip = @($results | Where-Object { $_.Verdict -in 'SKIP', 'PLANNED' }).Count
$total = $results.Count
$pct = if ($total) { [math]::Round(100 * ($pass + $fail) / $total, 1) } else { 0 }
Write-Output "TOTAL: $total   PASS: $pass   FAIL: $fail   SKIP/PLANNED: $skip   decided: $pct%"
if ($fail) {
    Write-Output ""
    Write-Output "FAILURES (รายการที่ไม่ผ่าน)"
    $results | Where-Object Verdict -eq 'FAIL' | ForEach-Object { "  $($_.File) / $($_.Id)  [$($_.Status)] $($_.Note)" }
}

if ($UpdateEnv) {
    if (-not $liveSession) { Write-Output "UPDATE-ENV: ไม่พบ PHPSESSID ที่ใช้งานได้จริงในรอบนี้" }
    else {
        $text = Get-Content $EnvFile -Encoding UTF8
        $text = $text -replace '(?m)^@session\s*=.*$', "@session = $liveSession"
        if (-not ($text -match '(?m)^@session\s*=')) { $text += "`n@session = $liveSession" }
        $text = $text -replace '(?m)^@authCookie\s*=.*$', "@authCookie = PHPSESSID=$liveSession; security_level=0"
        [System.IO.File]::WriteAllText($EnvFile, ($text -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "UPDATE-ENV: เขียน PHPSESSID $liveSession ลงใน $([System.IO.Path]::GetFileName($EnvFile))"
    }
}

# เขียน .vscode/settings.json ทุกครั้งที่มี session ใช้งานได้ ไม่ต้องรอ -UpdateEnv
# เพราะไฟล์นี้คือช่องทางเดียวที่ REST Client รู้จัก ถ้าไม่มี {{baseUrl}} จะหลุด
if ($liveSession) {
    $vars['session'] = $liveSession
    $vars['authCookie'] = "PHPSESSID=$liveSession; security_level=0"
    $rcFile = Set-RestClientVars -Root $Root -Vars $vars
    Write-Output "REST-CLIENT: เขียนตัวแปรลง .vscode\settings.json แล้ว (ถ้า VS Code ยังไม่เห็น ให้ Reload Window)"
}

# ---------------------------------------------------------------- results.json
# เขียนผลเป็น JSON ให้ New-Dashboard.ps1 เอาไปสร้างหน้าเว็บ
# เขียนเสมอแม้ไม่ใช้ -SaveEvidence เพราะไฟล์นี้เล็กมาก
if ($total -and -not $ReportOnly) {
    $payload = [pscustomobject]@{
        generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        baseUrl   = $vars['baseUrl']
        total     = $total
        pass      = $pass
        fail      = $fail
        planned   = $skip
        results   = @($results)
    }
    $jsonPath = Join-Path $evidenceDir 'results.json'
    if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null }
    [System.IO.File]::WriteAllText(
        $jsonPath,
        ($payload | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "RESULTS-JSON: $jsonPath"

    # ตัดหลักฐานเก่าทิ้ง เพื่อไม่ให้ไฟล์ค้างจากรอบก่อนปนกับผลรอบนี้
    # ทำเฉพาะตอนที่รันครบทุกไฟล์เท่านั้น ถ้ารันไฟล์เดียวจะไม่ไปลบหลักฐานของไฟล์อื่น
    $allFiles = @(Get-ChildItem (Join-Path $Root 'http') -Filter '*.http' -ErrorAction SilentlyContinue)
    $ranFiles = @($results | ForEach-Object { $_.File } | Sort-Object -Unique)
    if (-not $KeepStaleEvidence -and $allFiles.Count -and $ranFiles.Count -eq $allFiles.Count) {
        $keep = @{}
        foreach ($r in $results) { if ($r.Evidence) { $keep[$r.Evidence] = $true } }
        $stale = @(Get-ChildItem $evidenceDir -Filter '*.txt' -ErrorAction SilentlyContinue |
            Where-Object { -not $keep.ContainsKey($_.Name) })
        foreach ($f in $stale) { Remove-Item $f.FullName -Force }
        if ($stale.Count) { Write-Output "PRUNE-EVIDENCE: ลบหลักฐานเก่า $($stale.Count) ไฟล์ที่ไม่อยู่ในผลรอบนี้" }
    }
}

if ($Dashboard) {
    & (Join-Path $PSScriptRoot 'New-Dashboard.ps1')
}

if ($fail) { exit 1 }