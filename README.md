# project cyber - automated bWAPP web application security lab

A reproducible, self-contained penetration-testing lab for
[bWAPP](https://github.com/raesene/bWAPP), with 122 HTTP test cases that are
executed and verified automatically, and a full evidence trail.

Everything runs against a throwaway Docker container on `127.0.0.1:8080`.
Nothing here touches a network you do not own.

```
TOTAL: 122   PASS: 117   FAIL: 0   SKIP/PLANNED: 5   decided: 95.9%
```

## Requirements

- Windows PowerShell 5.1 (or PowerShell 7) - the scripts are written for 5.1
- Docker Desktop, running
- Nothing else. No PHP, no MySQL client, no `gh`, no Python on the host

## Quickstart

```powershell
# 1. start the lab, seed the database, make the upload dirs writable
.\scripts\setup-bwapp.ps1 -Reset

# 2. run every test case and capture the responses
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence

# 3. start over
.\scripts\setup-bwapp.ps1 -Reset
```

`setup-bwapp.ps1` is the only step that is genuinely necessary; step 2 logs in
on its own and needs no configuration.

Prefer Compose? `docker compose up -d` then run `setup-bwapp.ps1` without
`-Reset` - the seeding logic is identical.

## What the setup script fixes

The `raesene/bwapp:latest` image boots, but it is not usable as shipped:

| Problem | What the script does |
| --- | --- |
| MySQL starts **empty** - every page that reads data errors out | Reads `/var/www/html/db/bwapp.sqlite` from inside the container and replays it into MySQL, translating the DDL as well as the rows |
| SQLite has no `AUTO_INCREMENT`, so `blog.id` is not auto-assigned and the second INSERT collides on `id 0` | Restores `AUTO_INCREMENT` on single-column integer primary keys |
| The app's DB user cannot see the imported tables | `GRANT ALL ON bWAPP.*` |
| `images/`, `documents/` and `logs/` are read-only for `www-data`, so the file-upload finding cannot be demonstrated | `chmod 0777` on those three directories |
| No usable session for the test suite | Logs in as `bee`, verifies the 302, and writes the fresh `PHPSESSID` into `http-client.env` |

The script is idempotent: run it twice and the second run reports
`schema already present` and touches nothing.

## Layout

```
http-client.env            shared variables for the .http files (git-ignored;
                           http-client.env.example is the tracked template)
http/*.http                the test suites - plain HTTP, no framework
scripts/setup-bwapp.ps1    build the lab from nothing
scripts/Run-HttpFile.ps1   the .http parser, sender, verifier and reporter
scripts/validate.ps1       older batch validator, kept as a second opinion
scripts/probe.ps1          ad-hoc authenticated single request
evidence/                  captured responses (git-ignored, ~10 MB)
docs/report.md             the findings, written up
```

## The two runners

`Run-HttpFile.ps1` is the real one. It reads the `.http` files, so the tests
stay readable and can also be sent by hand from VS Code (REST Client) or
JetBrains. Each request carries machine-checkable expectations:

```http
### XSS-01 Reflected, GET parameters
GET {{baseUrl}}/xss_get.php?firstname=%3Cscript%3Ealert(1)%3C%2Fscript%3E&lastname=x HTTP/1.1

> {% response.status %}
```

- `> {% response.status %}` - expected status, `200|302` for alternatives
- `> {% response.body %}` - a substring that must be present
- `> {% response.header.X %}` - expected header value
- `> {% response.time %}` - timing assertions, used for blind injection
- `> {% not.response.body %}` - a **negative** control: the string must be absent
- a trailing `# Expect: ...` line - the same thing in prose, for editors that
  do not understand the directive syntax

Useful switches:

```powershell
-File 'http\*.http'     # glob, or a single file, or several
-Only 'SQLI-*'          # filter by test id
-SaveEvidence           # write every response to evidence/
-ShowBody               # dump bodies for the ones that fail
-UpdateEnv              # write the live session back to http-client.env
-ReportOnly             # re-print the previous result without sending anything
-NoAutoLogin            # use the session already in the env file
```

It also handles the things that make `.http` suites annoying in practice:
`{{variable}}` interpolation, a cookie jar, and **automatic re-login between
files** (bWAPP's `logout.php` destroys the session, and one file ending in a
logout would otherwise poison every file after it).

`validate.ps1` is an independent implementation - 75 cases, a different code
path, its own assertions. It is slower and less granular, but when the two
disagree, that is a real signal, not noise. Both currently report zero
failures, and both are re-runnable against the same container.

## Results

| Suite | Cases | Pass | Fail | Planned |
| --- | --- | --- | --- | --- |
| `Run-HttpFile.ps1` | 122 | 117 | 0 | 5 |
| `validate.ps1` | 75 | 75 | 0 | 0 |

Covered: SQL injection (15), XSS including stored and cookie-based (14),
local file read and source disclosure (9), OS command and PHP injection (11),
XXE/XML injection (7), mail header injection (2), unrestricted upload (4),
authentication and session flaws (14), CSRF (4), clickjacking (2), CORS (3),
information disclosure (17), host header and verb handling (5), and the DoS
surface (2).

The 5 planned cases are **client limitations, not untested findings** -
`System.Uri` and `HttpWebRequest` will not emit the malformed request lines
required. Each one is marked `PLANNED` in the runner output with the reason,
and each was confirmed by hand against the live target. See
[docs/report.md](docs/report.md) for the details.

## Safety

This image is deliberately full of unauthenticated RCE, SQL injection and LFI.

- The port is bound to `127.0.0.1` only. Do not publish it.
- There are no volume mounts, so an uploaded webshell cannot escape the
  container.
- The container is disposable. `-Reset` deletes it.

## Evidence

`evidence/` holds one file per verified response, named after the test. Each
contains the request that was sent and the full response, so a finding can be
re-checked without re-running anything:

```powershell
Get-Content .\evidence\INFO-01_the_ADMIN_endpoint_publishes_the_credentia.txt -TotalCount 40
```
