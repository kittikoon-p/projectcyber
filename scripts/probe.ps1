<#
    probe.ps1 - helper used while authoring the .http files.
    Logs into bWAPP, then fires a request and prints a compact result so payloads
    can be validated before they are committed to http/*.http.

    Usage:
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

function New-BwappSession {
    param([string]$BaseUrl, [int]$SecurityLevel)

    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    # security_level is a plain client-side cookie in bWAPP
    $cookie = New-Object System.Net.Cookie('security_level', "$SecurityLevel", '/', 'localhost')
    $sess.Cookies.Add($cookie)

    # bWAPP hashes the password with SHA1 and gates the form on `form`
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
Write-Output '--- body ---'
Write-Output $body
