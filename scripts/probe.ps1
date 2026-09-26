<#
    probe.ps1 - ตัวช่วยที่ใช้ระหว่างเขียนไฟล์ .http
    เข้าสู่ระบบ bWAPP แล้วยิงคำขอหนึ่งครั้ง พร้อมพิมพ์ผลแบบกระชับ เพื่อให้ตรวจสอบ
    payload ได้ก่อนที่จะบันทึกลง http/*.http

    วิธีใช้:
      .\probe.ps1 -Page sqli_1.php -Method GET
      .\probe.ps1 -Page directory_traversal_1.php -Params @{ directory = "../../../etc/passwd" }
      .\probe.ps1 -Page commandi.php -Params @{ ip = "127.0.0.1; id" } -ParamsOn QueryString
      .\probe.ps1 -Page xss_get.php -Params @{ text = "<script>alert(1)</script>" }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Page,
    [ValidateSet('GET', 'POST')][string]$Method = 'GET',
    [hashtable]$Params = @{},
    [switch]$ParamsOnQueryString,
    [int]$SecurityLevel = 0,
    [string]$BaseUrl = 'http://localhost:8080'
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 writes to the console using the OEM code page, so Thai text in
# these messages turns into mojibake unless the console is switched to UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }


function New-BwappSession {
    param([string]$BaseUrl, [int]$SecurityLevel)

    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    # security_level เป็นคุกกี้ฝั่ง client แบบธรรมดาใน bWAPP
    $cookie = New-Object System.Net.Cookie('security_level', "$SecurityLevel", '/', 'localhost')
    $sess.Cookies.Add($cookie)

    # bWAPP เข้ารหัสรหัสผ่านด้วย SHA1 และใช้ `form` เป็นตัวควบคุมฟอร์ม
    Invoke-WebRequest -Uri "$BaseUrl/login.php" -Method Post -WebSession $sess -UseBasicParsing -Body @{
        login          = 'bee'
        password       = 'bug'
        security_level = "$SecurityLevel"
        form           = 'submit'
    } | Out-Null

    return $sess
}

$session = New-BwappSession -BaseUrl $BaseUrl -SecurityLevel $SecurityLevel
$uri = "$BaseUrl/$Page"

if ($Method -eq 'GET' -and $Params.Count -gt 0) {
    $qs = ($Params.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))" }) -join '&'
    if ($qs) { $uri = "$uri`?$qs" }
    $Params = @{}
}

try {
    $res = Invoke-WebRequest -Uri $uri -Method $Method -Body $Params -WebSession $session -UseBasicParsing -TimeoutSec 20
    $body = $res.Content
} catch {
    $body = $_.Exception.Message
    $res = $null
}

$body | Out-File -Encoding utf8 "$env:TEMP\opencode\last_probe.html"
Write-Output "URL      : $uri"
Write-Output "Status   : $(if ($res) { $res.StatusCode } else { 'ERR' })"
Write-Output "Length   : $($body.Length)"
Write-Output "Saved    : $env:TEMP\opencode\last_probe.html"
Write-Output '--- body / เนื้อหา ---'
Write-Output $body