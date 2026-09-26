<#
    .SYNOPSIS
        Executes and verifies the request files in http/*.http without an IDE.

    .DESCRIPTION
        Parser + sender for the VS Code REST Client / JetBrains HTTP Client format.

        Request grammar
            ###                     comment / request title
            # comment               comment
            @name = value           variable assignment (http-client.env)
            GET /path HTTP/1.1      request line
            Header: value           request header
            <blank line>            end of headers; body follows verbatim

        Verification hints, read from the ### block above a request
            ### EXPECT-STATUS: 200            exact status to assert
            ### EXPECT-STATUS: 200|302        one of several acceptable statuses
            ### EXPECT-BODY: some substring    substring that must appear
            ### EXPECT-NOT: some substring     substring that must NOT appear
            ### EXPECT-HEADER: Name            response header that must be present
            ### SKIP                            report the case but do not send it

        A request with no hints is sent and only reported, never failed.

        Session handling
        00-auth.http logs in and its Set-Cookie fills an in-run cookie jar, so
        the remaining files inherit an authenticated session without a manual
        copy/paste. PHPSESSID learned during the run also overwrites {{session}}
        for the rest of the run, which is what stops stale Cookie: headers from
        http-client.env from overriding the fresh session.

    .EXAMPLE
        .\scripts\Run-HttpFile.ps1 -File http\00-auth.http
        .\scripts\Run-HttpFile.ps1 -File http\01-sqli.http -Only SQLI-03
        # full sweep, store responses, refresh @session for the IDE
        .\scripts\Run-HttpFile.ps1 -File http\*.http -SaveEvidence -UpdateEnv
        # report only
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
    [switch]$NoAutoLogin
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot -Parent
if (-not $EnvFile) { $EnvFile = Join-Path $Root 'http-client.env' }
$AutoLogin = -not $NoAutoLogin

# ---------------------------------------------------------------- variables
# Defaults come first so a fresh clone works with no http-client.env at all;
# anything the env file defines wins.
$defaults = @{
    baseUrl       = 'http://127.0.0.1:8080'
    bwappUser     = 'bee'
    bwappPass     = 'bug'
    securityLevel = '0'
    beeHash       = '6885858486f31043e5839c735d99457f045affd0'
    session       = ''
    authCookie    = ''
}
$vars = @{} + $defaults
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*@(\w+)\s*=\s*(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim() }
    }
}
# a blank value in the env file should not wipe out a working default
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

# ---------------------------------------------------------------- cookie jar
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
    # explicit values from the file win, the jar only fills the gaps
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

# ---------------------------------------------------------------- sender
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
            # HttpWebRequest rejects a Host equal to the URI authority, and only
            # permits an override when it differs (needed by the host-header tests)
            if ($Headers[$k] -ne $hostPart) { $req.Host = $Headers[$k] }
            continue
        }
        try { $req.Headers[$k] = $Headers[$k] } catch { Write-Verbose "header dropped: $k" }
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

# ---------------------------------------------------------------- parser
function New-Want {
    [ordered]@{ Status = $null; Body = @(); Not = @(); Header = @(); Skip = $false; Time = $null }
}

# One hint line -> one assertion. Accepts both the machine form
#   EXPECT-STATUS: 200|302 / EXPECT-BODY: x / EXPECT-NOT: x / EXPECT-HEADER: x
# and the prose form the suites are written in, e.g.
#   Expected: 200, body contains "marker"
function Add-Hint($want, [string]$text) {
    if ($text -match '^EXPECT-STATUS:\s*(\S+)') { $want.Status = @($Matches[1] -split '\|'); return }
    if ($text -match '^EXPECT-BODY:\s*(.+)$') { $want.Body += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-NOT:\s*(.+)$') { $want.Not += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-HEADER:\s*(.+)$') { $want.Header += $Matches[1].Trim(); return }
    if ($text -match '^EXPECT-TIME-AT-LEAST:\s*(\d+)') { $want.Time = [int]$Matches[1]; return }
    if ($text -match '^SKIP\b') { $want.Skip = $true; return }
    # prose fallback: never override an explicit EXPECT-* line with the same field
    if ($text -match 'Expected:\s*(\d{3})' -and -not $want.Status) { $want.Status = @($Matches[1]) }
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

    foreach ($raw in Get-Content $Path) {
        $line = $raw

        if ($line -match '^\s*###') {
            $text = ($line -replace '^\s*###+\s*', '').Trim()
            # A hint line right after a request documents THAT request, so it must
            # not close it. Anything else starts/extends the block for the next one.
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
            # copy out of $Matches immediately: any later -match clobbers it
            $mMethod = $Matches[1]
            $mUrl = $Matches[2]
            $noteSnapshot = @($notes)
            # -cmatch: the ID pattern is all-caps, so a lowercase filename in a
            # comment block (xxe-2.php, sqli_16.php) must not be mistaken for one
            $id = ($noteSnapshot | Where-Object { $_ -cmatch '^[A-Z]{2,}-\d+' } | Select-Object -First 1)
            $want = New-Want
            foreach ($n in $noteSnapshot) { Add-Hint $want $n }
            $cur = [pscustomobject]@{
                Id      = if ($id) { $id } else { ($noteSnapshot | Select-Object -First 1) }
                Notes   = New-Object System.Collections.ArrayList
                Method  = $mMethod
                Url     = $mUrl.Trim()
                Headers = @{}
                Body    = ''
                Want    = $want
            }
            $notes.Clear()
            $mode = 'headers'
        }
    }
    if ($cur) { [void]$requests.Add($cur) }
    # Blank lines between blocks otherwise accumulate into the body, which makes
    # HttpWebRequest reject a GET with "cannot send a content-body with this verb".
    foreach ($q in $requests) { if ($q.Body) { $q.Body = ($q.Body -replace '(\r?\n)+$', '') } }
    , $requests
}

# bWAPP calls session_regenerate_id() and logout.php destroys the session
# outright, so a run across several files has to log in again between them.
# Credentials come from http-client.env (@bwappUser / @bwappPass / @securityLevel).
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

# ---------------------------------------------------------------- run
$results = New-Object System.Collections.ArrayList
$evidenceDir = Join-Path $Root 'evidence'
$liveSession = $null
if ($SaveEvidence -and -not $ReportOnly) { New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null }

foreach ($f in $File) {
    # expand "http\*.http" - PowerShell does not glob a quoted path argument
    $matches = if ($f -match '[\*\?]') {
        @(Get-ChildItem -Path $f -File -ErrorAction SilentlyContinue | Sort-Object Name)
    } else { @($f) }
    if (-not $matches.Count) { Write-Output "!! no file matched: $f"; continue }

    foreach ($f in $matches) {
    $full = if ([System.IO.Path]::IsPathRooted($f)) { "$f" } else { Join-Path $Root "$f" }
    if (-not (Test-Path $full)) { Write-Output "!! missing: $f"; continue }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
    Write-Output ""
    Write-Output ("=" * 100)
    Write-Output "  $name.http"
    Write-Output ("=" * 100)

    # 00-auth.http demonstrates the login itself, so leave it alone
    if ($AutoLogin -and $name -ne '00-auth' -and -not $ReportOnly) {
        if (Login-Bwapp) { Write-Output "  (re-authenticated as $($vars['bwappUser']))" }
        else { Write-Output "  !! auto-login FAILED - results below will be unauthenticated" }
    }

    $reqs = Read-HttpFile -Path $full
    $n = 0
    foreach ($r in $reqs) {
        $n++
        $id = if ($r.Id) { "$($r.Id)" } else { "$name-$n" }
        $id = ($id -replace '\s+', ' ').Trim()
        if ($id.Length -gt 52) { $id = $id.Substring(0, 52) }
        if ($Only -and $id -notmatch $Only) { continue }

        $headers = @{}
        foreach ($k in $r.Headers.Keys) { $headers[$k] = Expand-Vars $r.Headers[$k] }
        $url = Expand-Vars $r.Url
        $body = Expand-Vars $r.Body
        if ($url -match '\{\{' -or ($body -match '\{\{')) {
            Write-Output ("  {0,-9} {1,-52} SKIP (unresolved variable)" -f 'UNRESOLVED', $id)
            [void]$results.Add([pscustomobject]@{ File = $name; Id = $id; Status = '-'; Verdict = 'SKIP' })
            continue
        }
        if ($r.Want.Skip -or $ReportOnly) {
            Write-Output ("  {0,-9} {1,-52} {2} {3}" -f 'PLANNED', $id, $r.Method, $url)
            [void]$results.Add([pscustomobject]@{ File = $name; Id = $id; Status = '-'; Verdict = 'PLANNED' })
            continue
        }

        # 00-auth.http ends with logout.php, which clears the jar. Put the session
        # back so the rest of the run stays authenticated.
        if ($liveSession -and -not $jar.ContainsKey('PHPSESSID')) { $jar['PHPSESSID'] = $liveSession }

        $res = Send-Request -Url $url -Method $r.Method -Headers $headers -Body $body
        if ($jar.ContainsKey('PHPSESSID') -and $jar['PHPSESSID']) {
            $liveSession = $jar['PHPSESSID']
            # keep {{session}} in step with the live session, otherwise a stale
            # Cookie: {{session}} header in a later file wins over the jar
            $vars['session'] = $liveSession
            $vars['authCookie'] = "PHPSESSID=$liveSession; security_level=0"
        }

        # ---- assertions
        $verdict = 'PASS'
        $why = @()
        if ($r.Want.Status) {
            if ($res.Status -notin $r.Want.Status) { $verdict = 'FAIL'; $why += "status $($res.Status) not in $($r.Want.Status -join '|')" }
        }
        # Global invariant: everything except the login/logout endpoints needs a
        # live session. A bounce back to login.php always means the session died.
        if ($url -notmatch '/(login|logout|security_level_set)\.php' -and
            $res.Status -eq 302 -and $res.Location -match 'login\.php') {
            $verdict = 'FAIL'; $why += 'bounced to login.php - session is not authenticated'
        }
        foreach ($b in $r.Want.Body) {
            if ($res.Body -notlike "*$b*") { $verdict = 'FAIL'; $why += "body missing '$b'" }
        }
        foreach ($b in $r.Want.Not) {
            if ($res.Body -like "*$b*") { $verdict = 'FAIL'; $why += "body must not contain '$b'" }
        }
        foreach ($h in $r.Want.Header) {
            $found = $false
            foreach ($k in $res.Headers.Keys) { if ($k -ieq $h -or $res.Headers[$k] -like "*$h*") { $found = $true; break } }
            if (-not $found) { $verdict = 'FAIL'; $why += "header missing '$h'" }
        }
        if ($r.Want.Time -and $res.Ms -lt $r.Want.Time) {
            $verdict = 'FAIL'; $why += "took $($res.Ms)ms, expected >= $($r.Want.Time)ms"
        }
        # a request that is neither 2xx nor carrying a stated expectation is a miss
        if (-not $r.Want.Status -and $res.Status -ge 400) { $verdict = 'FAIL'; $why += "unexpected $($res.Status)" }

        $loc = if ($res.Location) { " -> $($res.Location)" } else { '' }
        $note = if ($why) { '  [' + ($why -join '; ') + ']' } else { '' }
        Write-Output ("  {0,-9} {1,-52} {2} {3} {4} bytes {5}ms{6}{7}" -f `
            $verdict, $id, $r.Method, ($url -replace [regex]::Escape($vars['baseUrl']), ''), $res.Body.Length, $res.Ms, $loc, $note)
        [void]$results.Add([pscustomobject]@{ File = $name; Id = $id; Status = $res.Status; Verdict = $verdict; Note = ($why -join '; ') })

        if ($SaveEvidence) {
            $safe = ($id -replace '[^A-Za-z0-9._-]', '_')
            if ($safe.Length -gt 70) { $safe = $safe.Substring(0, 70) }
            $dest = Join-Path $evidenceDir "$name__$safe.txt"
            $hdrLines = ($res.Headers.Keys | Sort-Object | ForEach-Object { "$_`: $($res.Headers[$_])" }) -join "`n"
            @("$id", "$($r.Method) $url", "HTTP $($res.Status)  ($($res.Ms) ms)", "", "--- response headers ---", $hdrLines, "", "--- body ---", $res.Body) |
                Out-File -Encoding utf8 $dest
        }
        if ($ShowBody) {
            Write-Output '      --- body (first 1500 chars) ---'
            $snippet = if ($res.Body.Length -gt 1500) { $res.Body.Substring(0, 1500) } else { $res.Body }
            Write-Output ($snippet -split "`n" | ForEach-Object { "      $_" })
        }
    }
    }
}

# ---------------------------------------------------------------- summary
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
    Write-Output "FAILURES"
    $results | Where-Object Verdict -eq 'FAIL' | ForEach-Object { "  $($_.File) / $($_.Id)  [$($_.Status)] $($_.Note)" }
}

if ($UpdateEnv) {
    if (-not $liveSession) { Write-Output "UPDATE-ENV: no live PHPSESSID was captured" }
    else {
        $text = Get-Content $EnvFile
        $text = $text -replace '(?m)^@session\s*=.*$', "@session = $liveSession"
        if (-not ($text -match '(?m)^@session\s*=')) { $text += "`n@session = $liveSession" }
        $text = $text -replace '(?m)^@authCookie\s*=.*$', "@authCookie = PHPSESSID=$liveSession; security_level=0"
        [System.IO.File]::WriteAllText($EnvFile, ($text -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "UPDATE-ENV: PHPSESSID $liveSession written to $([System.IO.Path]::GetFileName($EnvFile))"
    }
}

if ($fail) { exit 1 }
