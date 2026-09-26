<#
    .SYNOPSIS
        Brings up a disposable bWAPP instance and prepares it for this test suite.

    .DESCRIPTION
        The raesene/bwapp image ships a working PHP/Apache stack but an EMPTY
        MySQL database - the app boots, but every page that reads data fails.
        The seed data lives in /var/www/html/db/bwapp.sqlite, so this script
        converts that SQLite file into the MySQL schema the app expects.

        It also makes the upload targets writable. The image ships images/ and
        documents/ read-only for the www-data user, so the file-upload finding
        (UPL-01..04) cannot be demonstrated until they are chmod'ed.

        Everything here is destructive to the container and nothing here touches
        the host. Delete the container and re-run to get a clean lab.

    .PARAMETER Port
        Host port to publish. Default 8080.

    .PARAMETER Reset
        Remove and recreate an existing container first.

    .EXAMPLE
        .\scripts\setup-bwapp.ps1
        .\scripts\setup-bwapp.ps1 -Port 9090 -Reset
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$Container = 'bwapp',
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    ok: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }

# Native commands write progress to stderr, which PowerShell 5.1 turns into a
# terminating error under $ErrorActionPreference = 'Stop'. Route them through
# these helpers so a non-zero exit is a return value, not an exception.
# The tail comes from $args on purpose: docker flags such as -a / --filter would
# otherwise be swallowed by PowerShell's parameter binder, and embedded double
# quotes are stripped from native arguments by PowerShell 5.1 - which is why all
# SQL is piped over stdin instead of passed with -e "...".
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

# SQL goes in on stdin: no shell quoting to get wrong.
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

# ---------------------------------------------------------------- docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH - install Docker Desktop first"
}
$daemon = Run-Native docker info
if ($daemon.Exit -ne 0) { throw "docker daemon is not reachable - start Docker Desktop and retry" }

# ---------------------------------------------------------------- container
$existing = (Run-Native docker ps -a --filter "name=^/$Container$" --format '{{.Names}}').Out
if ($existing -and $Reset) {
    Step "removing existing container '$Container'"
    Run-Native docker rm -f $Container *> $null
    $existing = ''
}
if (-not $existing) {
    Step "starting raesene/bwapp:latest as '$Container' on 127.0.0.1:$Port"
    $run = Run-Native docker run -d --name $Container -p "127.0.0.1:${Port}:80" raesene/bwapp:latest
    if ($run.Exit -ne 0) { throw "docker run failed:`n$($run.Out)" }
}

Step "waiting for Apache on 127.0.0.1:$Port"
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
            # any HTTP answer at all means Apache is up; 302 is the GET /login.php
            # redirect for an expired session
            $ready = $true; break
        }
        $lastApacheError = $_.Exception.Message
        # "connection closed" / "state of the object" are the .NET/PowerShell
        # client misbehaving, not Apache failing, so they must not end the wait
    }
}
if (-not $ready) { throw "Apache did not come up ($lastApacheError) - check: docker logs $Container" }
Ok "login.php is answering"

# ---------------------------------------------------------------- database
# MySQL initialises on first boot and is not ready when Apache starts answering.
Step "waiting for MySQL inside the container"
$dbReady = $false
foreach ($i in 1..60) {
    if ((Invoke-Mysql 'SELECT 1' -NoHeader).Exit -eq 0) { $dbReady = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $dbReady) { throw "MySQL never became ready - check: docker logs $Container" }
Ok "MySQL is accepting connections"

Step "checking the bWAPP MySQL schema"
if ((Invoke-Mysql 'USE bWAPP; SELECT 1 FROM users LIMIT 1;' -NoHeader).Exit -eq 0) {
    Ok "schema already present"
} else {
    Warn "bWAPP database is empty (this is the stock image state) - importing"

    # SQLite cannot be replayed into MySQL directly, so translate both the DDL
    # and the rows. The app reads specific column names, so the CREATE TABLE
    # statements are generated from the seed file rather than hand-written.
    $py = @'
import re, sqlite3
con = sqlite3.connect("/var/www/html/db/bwapp.sqlite")
cur = con.cursor()

def to_mysql(ddl):
    ddl = ddl.replace('"', "`")                      # "col" -> `col`
    ddl = re.sub(r"\bint\(\d+\)", "int(10)", ddl)   # sqlite int(N) -> mysql int(10)
    ddl = re.sub(r"\bAUTOINCREMENT\b", "AUTO_INCREMENT", ddl)
    # SQLite has no AUTO_INCREMENT - it uses an implicit rowid. bWAPP's INSERTs
    # never supply `id`, so a single-column integer primary key has to be
    # AUTO_INCREMENT in MySQL or the first two inserts collide on id 0.
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

    # generate the SQL inside the container, then stream it back in
    $gen = Run-Native docker exec $Container python3 /tmp/bwapp-seed.py
    if ($gen.Exit -ne 0) { throw "seed generation failed:`n$($gen.Out)" }
    Ok "generated: $($gen.Out)"
    $seed = Run-Native docker exec $Container cat /tmp/seed.sql
    if (-not $seed.Out.Trim()) { throw "seed file is empty - is /var/www/html/db/bwapp.sqlite present?" }

    $import = Invoke-Mysql $seed.Out
    if ($import.Exit -ne 0) { throw "import failed:`n$($import.Out)" }

    $users = (Invoke-Mysql 'USE bWAPP; SELECT COUNT(*) FROM users;' -NoHeader).Out
    if ($users -match '^\d+$' -and [int]$users -gt 0) { Ok "imported $users users" }
    else { throw "import produced no users (got: '$users')" }

    # Importing a few hundred rows can knock a starting MySQL over; make sure it
    # came back before anything else touches the database.
    Step "re-checking MySQL after the import"
    $back = $false
    foreach ($i in 1..40) {
        if ((Invoke-Mysql 'SELECT 1' -NoHeader).Exit -eq 0) { $back = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $back) { throw "MySQL did not survive the import - check: docker logs $Container" }
    Ok "MySQL is back up"
}

# the app connects with its own MySQL account, so it needs its own grants
$grant = Invoke-Mysql "GRANT ALL ON bWAPP.* TO 'bWAPP'@'localhost'; FLUSH PRIVILEGES;"
if ($grant.Exit -ne 0) { Warn "grant failed: $($grant.Out)" } else { Ok "granted bWAPP.* to the app's DB user" }

$counts = Invoke-Mysql @'
USE bWAPP;
SELECT CONCAT('users=', (SELECT COUNT(*) FROM users),
              ' movies=', (SELECT COUNT(*) FROM movies),
              ' heroes=', (SELECT COUNT(*) FROM heroes),
              ' blog=',  (SELECT COUNT(*) FROM blog));
'@ -NoHeader
Ok "row counts: $($counts.Out)"

# ---------------------------------------------------------------- writability
# Without this the upload tests cannot land a file at all: the image ships these
# directories without write permission for uid=33 (www-data).
Step "making the upload targets writable"
Run-Native docker exec $Container sh -c 'mkdir -p /app/logs && chmod 0777 /app/logs /app/images /app/documents' *> $null
$mode = Run-Native docker exec $Container sh -c 'stat -c %a:%n /app/images /app/documents /app/logs'
foreach ($line in ($mode.Out -split "`n" | Where-Object { $_ })) { Ok "chmod $line" }

# ---------------------------------------------------------------- sanity
Step "verifying the default credentials work"
# NOTE: Invoke-WebRequest cannot be used here. PowerShell 5.1 throws
# "Operation is not valid due to the current state of the object" when
# -WebSession is combined with -MaximumRedirection 0, which is exactly what
# reading a session cookie off a 302 requires. Use HttpWebRequest directly.
# bWAPP sends two PHPSESSIDs in one header (pre- and post-regenerate); the
# regenerated one comes last and is the valid session.
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
            if ($c -match '^\s*(PHPSESSID)=([^;]+)') { $sid = $Matches[2] }   # last one wins
        }
        $resp.Close()
        if ($loginStatus -eq 302 -and $sid) { break }
    } catch {
        $sid = ''
        $loginError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 750   # a worker can still be settling after the import
}
if ($loginStatus -eq 302 -and $sid) { Ok "login returned 302 -> portal.php with a valid session" }
else { Warn "login did not return a usable session (status $loginStatus, '$loginError')" }

if ($sid) {
    Ok "PHPSESSID=$sid"
    $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'http-client.env'
    if (Test-Path $envFile) {
        $text = Get-Content $EnvFile
        $text = $text -replace '(?m)^@baseUrl\s*=.*$', "@baseUrl = http://127.0.0.1:$Port"
        $text = $text -replace '(?m)^@session\s*=.*$', "@session = $sid"
        $text = $text -replace '(?m)^@authCookie\s*=.*$', "@authCookie = PHPSESSID=$sid; security_level=0"
        [System.IO.File]::WriteAllText($envFile, ($text -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Ok "wrote the live session into http-client.env"
    }
} else { Warn "no usable PHPSESSID - run the suite and pass -UpdateEnv to refresh it" }

# ---------------------------------------------------------------- summary
$hash = ''
foreach ($i in 1..10) {
    $r = Invoke-Mysql "USE bWAPP; SELECT password FROM users WHERE login = 'bee';" -NoHeader
    if ($r.Exit -eq 0 -and $r.Out -match '^[0-9a-f]{40}$') { $hash = $r.Out; break }
    Start-Sleep -Milliseconds 500
}
if (-not $hash) { Warn "could not read the stored password hash back from MySQL" }
Write-Host ""
Write-Host "  bWAPP is ready at  http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "  credentials      bee / bug   (SHA1 stored: $(if ($hash) { $hash } else { 'unavailable' }))" -ForegroundColor Gray
Write-Host "  run the suite    .\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence -UpdateEnv" -ForegroundColor Gray
Write-Host "  clean slate      .\scripts\setup-bwapp.ps1 -Reset" -ForegroundColor Gray
Write-Host ""
