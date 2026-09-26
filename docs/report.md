# bWAPP security assessment - findings

**Target** `http://127.0.0.1:8080` (Docker container `bwapp`, image
`raesene/bwapp:latest`)
**Scope** the whole application, authenticated as `bee` and unauthenticated
**Method** 122 automated HTTP test cases, each with machine-checked assertions
and a captured response
**Result** 117 pass, 0 fail, 5 planned - see [Limitations](#limitations)

Every finding below is reproducible from the repository:

```powershell
.\scripts\setup-bwapp.ps1 -Reset
.\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence
```

Evidence lives in `evidence/`, one file per case, containing the request that
was sent and the full response.

---

## Severity summary

| Severity | Count | Examples |
| --- | --- | --- |
| Critical | 5 | unauthenticated RCE, credential disclosure, full DB compromise |
| High | 11 | account takeover, privilege escalation, stored XSS |
| Medium | 9 | CSRF, open redirect, CORS, clickjacking, enumeration |
| Low / Info | 6 | banners, robots.txt, TRACE, directory listing |
| Negative results | 5 | things that are *not* broken - recorded on purpose |

The severity ratings below describe the bWAPP application as it ships. bWAPP is
an intentionally vulnerable training target, so "critical" here means "correctly
identified", not "unexpected".

---

## Critical

### 1. Unauthenticated remote code execution via file upload
`UPL-01`, `UPL-02`, `UPL-03` · `POST /unrestricted_file_upload.php`

The upload endpoint applies no validation on file type or extension. A PHP
webshell is accepted, written into the webroot, and executed by the server as
`www-data`:

```
POST /unrestricted_file_upload.php      -> 13430 bytes
GET  /images/shell.php?c=id             -> 54 bytes, "uid=33(www-data)"
GET  /images/shell.php?c=cat /app/admin/settings.php
```

`UPL-02` is the confirmation: the uploaded file is not merely stored, it runs.
`UPL-03` reads the application's own database configuration back out through
it, chaining straight into finding 2.

The image ships `images/` and `documents/` read-only for `www-data`, so this
is unreachable until `setup-bwapp.ps1` chmods them. That is an artefact of the
image, not a mitigation.

### 2. Unauthenticated disclosure of database and SMTP credentials
`INFO-01` · `GET /admin/` -> 3156 bytes

`/admin/` is reachable with no session and publishes the MySQL credentials,
the SMTP password and the admin login. It is the first thing an attacker
would read, and it hands over everything else.

The same page is also reachable through the traversal bug
(`INFO-02`, `LFI-05`), so it cannot be fixed by blocking the one path.

### 3. SQL injection - full database compromise
`SQLI-01` .. `SQLI-15` · 15 distinct injection points

Not one injection point but fifteen, across every sink shape the app has:

| Shape | Cases |
| --- | --- |
| Boolean-based | `SQLI-01`, `SQLI-06`, `SQLI-07`, `SQLI-14` |
| UNION-based | `SQLI-02` (column count), `SQLI-03` (full `users` dump), `SQLI-04`, `SQLI-05`, `SQLI-11` |
| Error/context-based | `SQLI-04`, `SQLI-05`, `XXI-03` |
| Stacked / subquery | `SQLI-12` |
| POST / LIKE | `SQLI-08` |
| Login-form auth bypass | `SQLI-09`, `SQLI-10`, `SQLI-15` |
| Over XML | `SQLI-13` |
| AJAX / JSON endpoint | `SQLI-11` |

`SQLI-03` recovers the whole `users` table including password hashes:

```
0 UNION SELECT 1,GROUP_CONCAT(login),GROUP_CONCAT(password),4,5,6 FROM users-- -
```

which yields `bee:6885858486f31043e5839c735d99457f045affd0` - the SHA1 of
`bug`, the documented password. Cracking it is trivial, so this is
authentication bypass in practice.

`SQLI-15` is the sharpest version: the same trick against the **real**
`login.php`, not a demo endpoint.

### 4. Authentication bypass on the login form
`SQLI-15`, `AUTH-02`, `AUTH-03`, `AUTH-11`

Four independent ways past the login:

- `SQLI-15` - `' OR 1=1-- -` in the username field
- `AUTH-02` - classic SQLi auth bypass
- `AUTH-03` - the password is never actually checked client-side
- `AUTH-11` - LDAP wildcard (`*`) returns the first directory entry

Any one of these is a full compromise. Finding 3 is the underlying cause for
two of them; the other two are independent implementation flaws.

### 5. Local file read reaching the whole filesystem, plus source disclosure
`LFI-01` .. `LFI-07`

`directory_traversal_1.php` takes an unchecked path:

```
GET /directory_traversal_1.php?page=../../../../../../../etc/passwd   -> /etc/passwd
GET /directory_traversal_1.php?page=admin/settings.php               -> PHP source
```

Reading PHP as text returns the source, which is how the credentials in
finding 2 are reachable through a second path. `directory_traversal_2.php`
additionally lists arbitrary directories (`LFI-06`, `LFI-07`), exposing the
whole webroot.

`LFI-03` reads the Apache access log, which is the standard pivot into log
poisoning and then RCE.

---

## High

### 6. Stored XSS, two independent sinks
`XSS-10`, `XSS-11`, `XSS-12`

- `XSS-10` - persists in the blog and is served to every visitor
- `XSS-11` / `XSS-12` - a two-step, second-order chain: the payload is stored
  in the user profile, then fires on a *different* page when the profile is
  rendered

Stored XSS in a session-authenticated app means session theft and full account
takeover. The second-order variant is the more interesting one, because no
filter applied at storage time would ever catch it.

### 7. Reflected XSS across every input channel
`XSS-01` .. `XSS-05`, `XSS-07`, `XSS-08`, `XSS-09`, `XSS-13`

The app reflects unescaped input from GET parameters, POST bodies, the
`Referer` header, the `User-Agent` header, an arbitrary custom header, an
`<a href>`, a `javascript:` URL, a JSON response context, a cookie, and an
`eval()` sink.

`XSS-14` records the boundary honestly: at the *medium* security level the
same payload is escaped and does not fire. The protection exists and works -
it is simply not on by default.

### 8. IDOR - read and write other users' data
`AUTH-10`, `XXI-04`

`AUTH-10` overwrites another user's `secret` by changing the `login`
parameter. `XXI-04` does the same over the XML endpoint. Neither checks that
the authenticated user owns the record.

### 9. Privilege escalation to administrator
`CSRF-02`

`csrf_2.php` creates a **new administrator account** with no CSRF token and no
authorization check. One request, full admin.

### 10. Password change with no CSRF token and no old-password check
`AUTH-07`, `CSRF-01`

The authenticated user's password can be changed by a forged cross-site
request, without the current password. Combined with finding 9 this is a
complete takeover chain. `AUTH-08` restores the lab password afterwards, so
the suite is re-runnable.

### 11. Session management failures
`AUTH-13`, `AUTH-14`, `INFO-09`

- `AUTH-14` - a session id supplied by the client is accepted (session fixation)
- `AUTH-13` / `INFO-09` - the "security level" is a **client-side cookie**.
  Setting it to `2` makes the app *display* as fully hardened while every
  underlying vulnerability still works

`INFO-09` is the most consequential finding in the report after the RCE,
because it means the application's own security indicator is attacker-
controlled. An assessor who trusted it would misjudge the whole system.

### 12. OS command injection
`CMDI-01` .. `CMDI-09`

Five separators work (`;`, `|`, `&&`, `&`, `%0a`), the injected output
replaces the legitimate one, and files can be read directly. `CMDI-08` and
`CMDI-09` confirm **blind** injection out-of-band with a timing oracle: a
5-second `sleep` produced a 5009 ms response against a 3 ms baseline.

`CMDI-07` is an interactive reverse shell, exercised as a payload shape only -
nothing was left listening.

### 13. PHP code injection
`CODE-01`, `CODE-02`

`php_eval.php` passes request data to `eval()`. `system("id")` executes;
arbitrary PHP reads the application's own source back out.

### 14. XML injection into SQL, and broken access control over XML
`XXI-01` .. `XXI-04`

`xxe-2.php` builds SQL by string-concatenating XML node values, so the XML is
an injection surface in its own right. `XXI-01` writes to
`users.secret`; `XXI-02` and `XXI-03` confirm boolean injection and a verbose
error leak; `XXI-04` resets **another** user's secret.

### 15. Unauthenticated secret disclosure
`AUTH-09` · `GET /secret.php` -> 14 bytes

Returns the current user's secret with no authorization check. `INFO-02` and
`LFI-09` show the same class of failure elsewhere.

### 16. Mail header injection
`MAIL-01`, `MAIL-02`

CRLF into the e-mail field injects additional recipients via `Cc:`, and the
`Subject` field is injectable too. With control of the `From` address this is
a credible phishing primitive.

---

## Medium

| ID | Finding | Notes |
| --- | --- | --- |
| `CSRF-03` | Destructive action - delete blog entries, no token | Data destruction via a forged request |
| `CSRF-04` | CSRF demonstrated with an explicit foreign `Origin` | Confirms the browser would actually send it |
| `CLICK-01`, `CLICK-02` | No `X-Frame-Options` / `frame-ancestors` | Framing works on `/admin/` too, not just the demo page |
| `CORS-01` | `Access-Control-Allow-Origin: *` on a secret endpoint | Any site can read it |
| `CORS-02` | Over-narrow allow-list that still reflects the `Origin` header | The check is substring-based and bypassable |
| `INFO-10`, `INFO-11`, `INFO-12` | Open redirect x3 - `url`, `ReturnUrl`, protocol-relative and `javascript:` | The `javascript:` variant is worse than a redirect: it is XSS in a redirect parameter |
| `AUTH-05` | User enumeration via the forgotten-password oracle | Different response for valid vs invalid users |
| `AUTH-12` | Business logic - negative ticket price accepted | Integrity failure, not injection |
| `XXE` | XXE is **blocked** - see negative results | libxml 2.9 defaults |

`CORS-03` is recorded as a negative control: it confirms the CORS tests are
detecting the header rather than merely detecting a 200 response.

---

## Low / informational

| ID | Finding |
| --- | --- |
| `INFO-03`, `LFI-08` | `phpinfo()` exposed to any authenticated user - ~80 KB of full server configuration |
| `INFO-04` | Verbose error reporting on - a missing page returns the error text |
| `INFO-05` | Directory listing enabled on `/images/` |
| `INFO-06` | `robots.txt` discloses paths |
| `VERB-01` | `TRACE` is enabled and echoes the request |
| `INFO-16` | `backdoor.php` upload helper is reachable |
| `INFO-15` | `User-Agent` and client IP written to the database unsanitised |
| `INFO-13` | HTML/tag injection - markup rendered, but not executable |
| `DOS-01`, `DOS-02` | Resource-exhaustion surface, incl. a 4.9 MB response via the include bug |

---

## Negative results

Recorded deliberately. A test that asserts a vulnerability is *absent* is only
meaningful if you can show it would have caught a real one, so each of these is
paired with the positive case that proves the detector works.

| ID | Not vulnerable | Proof the test is real |
| --- | --- | --- |
| `XXE-01`, `XXE-02`, `XXE-03` | External entities are not resolved - no local file read, no SSRF | The same endpoint *is* injectable via `XXI-01` |
| `INFO-17` | `login.php` correctly escapes its output | `XSS-01` shows the identical payload firing elsewhere |
| `CORS-03` | `secret-cors-3.php` leaks data but sends no CORS header | `CORS-01` and `CORS-02` do send them |
| `SQLI-07` | The FALSE branch of the boolean test does **not** match | The TRUE branch does - so the assertion is discriminating |
| `AUTH-08` | The lab password is restored after `AUTH-07` | Keeps the suite re-runnable |

The XXE result is the interesting one: the app *looks* like it has an XXE
endpoint, and the payload shape is textbook. libxml 2.9's defaults block it.
Reporting it as a finding would have been wrong.

---

## Limitations

Five cases are `PLANNED` - the request cannot be emitted by
`System.Net.HttpWebRequest`, which is the only HTTP client available in
Windows PowerShell 5.1 without installing anything. Each was confirmed by hand
against the live target, so none of them is an untested finding.

| ID | What the client refuses to send | Verified manually |
| --- | --- | --- |
| `XSS-06` | `GET /xss_php_self.php/%3Cscript%3E...` - `System.Uri` un-escapes `%3C`/`%3E` into literal `<` `>`, which the server 404s | Yes - raw request reflects `<form action="/xss_php_self.php/<script>alert(1)</script>" method="GET">` |
| `SM-01` (file 07) | `CL.TE` disagreement - the client rewrites the framing | Yes, as a surface |
| `SM-01`, `SM-02` (file 09) | Duplicate `Transfer-Encoding` headers, for obfuscation | Yes, as a surface |
| `HOST-03` | Absolute-form request line (`GET http://attacker.evil.com/...`) - rewritten to origin-form | Yes, as a surface |

Two further notes on honesty of scope:

- **`XSS-06` is confirmed exploitable but not by this runner.** The evidence is
  the raw-request reflection above. It is deliberately reported as `PLANNED`
  rather than `PASS` so the automated totals never overstate what the tooling
  actually did.
- **Request smuggling is a surface, not a proven desync.** A single-request
  client cannot demonstrate poisoning a *second* request. Reporting a
  confirmed desync here would be unsupported.

Other scope boundaries:

- The suite runs as `bee` at security level 0. Level 1 and 2 behaviour is
  sampled (`XSS-14`) but not swept.
- LDAP injection (`AUTH-11`) is verified against bWAPP's simulated LDAP, not a
  real directory.
- Timing-based findings (`CMDI-08`, `CMDI-09`) are single-sample. On a loaded
  machine the 5009 ms vs 3 ms gap is unambiguous, but this is not a
  statistically rigorous timing study.

---

## Remediation priorities

1. **Remove the arbitrary-upload endpoint, or validate and relocate uploads.**
   Findings 1 and 12 are the whole ballgame; everything else is recoverable.
2. **Delete `/admin/`, or put it behind real authentication.** It publishes
   every credential in the application.
3. **Parameterise every query.** Fifteen injection points are one habit, not
   fifteen bugs.
4. **Escape on output, centrally, for every context** - HTML, attribute, JS,
   URL, CSS. The number of XSS sinks tracks the number of places output is
   built by hand.
5. **Make the security level server-side.** A cookie the client controls is not
   a control.
6. **Add authorization checks to every object reference**, and CSRF tokens to
   every state-changing request.
7. **Turn off `phpinfo()`, directory listing, `TRACE` and verbose errors**, and
   store passwords with a memory-hard hash instead of SHA1.
