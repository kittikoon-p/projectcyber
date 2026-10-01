<#
    .SYNOPSIS
        สร้างหน้าเว็บ dashboard แบบไฟล์เดียว จากผลการทดสอบที่ runner เขียนไว้

    .DESCRIPTION
        อ่าน evidence/results.json ที่ Run-HttpFile.ps1 เขียนไว้ แล้วสร้าง
        dashboard.html ไฟล์เดียวที่ฝังข้อมูลไว้ข้างใน

        ไฟล์ที่ได้ไม่พึ่ง CDN, ไม่ต้องติดตั้งอะไร และเปิดด้วย file:// ได้เลย
        เพราะข้อมูลถูกฝังไว้ในไฟล์ ไม่ใช่ดึงมาด้วย fetch() ซึ่งถูก CORS บล็อก

        ต้องรันหลัง Run-HttpFile.ps1 เสมอ เพราะ dashboard เป็นภาพ snapshot
        ของผลรอบล่าสุด ไม่ใช่ตัวรันเทสต์เอง

    .PARAMETER OutFile
        ตำแหน่งที่จะเขียน dashboard.html ค่าเริ่มต้นคือรากโปรเจกต์

    .EXAMPLE
        .\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence
        .\scripts\New-Dashboard.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot -Parent
$jsonPath = Join-Path $Root 'evidence\results.json'
if (-not $OutFile) { $OutFile = Join-Path $Root 'dashboard.html' }

if (-not (Test-Path $jsonPath)) {
    throw "ไม่พบ $jsonPath - ต้องรัน Run-HttpFile.ps1 ก่อน เช่น:`n  .\scripts\Run-HttpFile.ps1 -File 'http\*.http' -SaveEvidence"
}

$data = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $data.results -or -not $data.results.Count) { throw "results.json ไม่มีข้อมูลผลการทดสอบ" }

# ---------------------------------------------------------------- ฝังข้อมูลลง HTML
# ข้อมูลถูกฝังไว้ใน <script> ต้อง escape เครื่องหมาย < เป็น \u003c ไม่ให้ </script> หลุดออกมา
$jsonForHtml = ($data | ConvertTo-Json -Depth 6 -Compress) -replace '<', '\u003c'

# เตรียมรายการไฟล์สำหรับตัวกรอง
$files = @($data.results | ForEach-Object { $_.File } | Sort-Object -Unique)

$html = @"
<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>bWAPP - ผลการทดสอบความปลอดภัย</title>
<style>
  :root {
    --bg: #0d1117;
    --panel: #161b22;
    --line: #262d36;
    --text: #e6edf3;
    --muted: #8b949e;
    --pass: #3fb950;
    --fail: #f85149;
    --planned: #d29922;
    --accent: #58a6ff;
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans Thai", "Leelawadee UI", Roboto, sans-serif;
  }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 48px 24px 96px; }

  header { margin-bottom: 32px; }
  h1 { margin: 0 0 4px; font-size: 20px; font-weight: 600; letter-spacing: -0.01em; }
  .sub { color: var(--muted); font-size: 13px; }

  /* แถบสรุปตัวเลข */
  .stats { display: flex; gap: 8px; flex-wrap: wrap; margin: 24px 0 28px; }
  .stat {
    flex: 1 1 120px; padding: 14px 16px;
    background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
  }
  .stat b { display: block; font-size: 22px; font-weight: 600; line-height: 1.2; font-variant-numeric: tabular-nums; }
  .stat span { color: var(--muted); font-size: 12px; }
  .stat.pass b { color: var(--pass); }
  .stat.fail b { color: var(--fail); }
  .stat.planned b { color: var(--planned); }

  /* แถบควบคุม */
  .bar { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 8px; }
  .chip {
    padding: 5px 12px; border: 1px solid var(--line); border-radius: 999px;
    background: transparent; color: var(--muted); cursor: pointer;
    font: inherit; font-size: 13px;
  }
  .chip:hover { border-color: var(--muted); color: var(--text); }
  .chip[aria-pressed="true"] { background: var(--accent); border-color: var(--accent); color: #04121f; font-weight: 600; }
  .spacer { flex: 1; }
  input[type=search] {
    flex: 1 1 200px; min-width: 160px; padding: 6px 12px;
    background: var(--bg); color: var(--text);
    border: 1px solid var(--line); border-radius: 999px; font: inherit; font-size: 13px;
  }
  input[type=search]:focus { outline: none; border-color: var(--accent); }

  /* หัวตาราง */
  .head, .row {
    display: grid;
    grid-template-columns: 22px 118px 1fr 54px 46px 54px;
    gap: 12px; align-items: center;
  }
  .head {
    padding: 0 12px 8px; color: var(--muted);
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em;
    border-bottom: 1px solid var(--line);
  }
  .head .num, .row .num { text-align: right; font-variant-numeric: tabular-nums; }

  /* แถวผลการทดสอบ */
  .row {
    padding: 9px 12px; border-radius: 6px; cursor: pointer;
    border: 1px solid transparent;
  }
  .row:hover { background: var(--panel); }
  .row.open { background: var(--panel); border-color: var(--line); }
  .dot { width: 8px; height: 8px; border-radius: 50%; }
  .dot.pass { background: var(--pass); }
  .dot.fail { background: var(--fail); }
  .dot.planned { background: var(--planned); }
  .id { color: var(--accent); font-size: 12px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .num { color: var(--muted); font-size: 12px; }
  .row.fail .name { color: var(--fail); }
  .row.planned .name { color: var(--muted); }

  /* แผงรายละเอียดเมื่อกดแถว */
  .detail { display: none; padding: 4px 12px 16px 46px; }
  .row.open + .detail { display: block; }
  .detail dl { display: grid; grid-template-columns: 72px 1fr; gap: 6px 12px; margin: 0 0 10px; }
  .detail dt { color: var(--muted); font-size: 12px; }
  .detail dd { margin: 0; font-size: 13px; word-break: break-all; }
  .detail code {
    font: 12px/1.5 ui-monospace, SFMono-Regular, "Cascadia Code", Consolas, monospace;
    background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px;
  }
  .why { color: var(--planned); }
  .why.failed { color: var(--fail); }
  a { color: var(--accent); }
  .empty { padding: 48px 12px; text-align: center; color: var(--muted); }
  footer { margin-top: 40px; color: var(--muted); font-size: 12px; }
  code.k { color: var(--muted); }
  @media (max-width: 720px) {
    .head, .row { grid-template-columns: 22px 1fr 46px; }
    .head .hide, .row .hide { display: none; }
    .detail { padding-left: 12px; }
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>bWAPP &mdash; ผลการทดสอบความปลอดภัย</h1>
    <div class="sub">สร้างเมื่อ $($data.generated) &middot; เป้าหมาย <code class="k">$($data.baseUrl)</code></div>
  </header>

  <div class="stats">
    <div class="stat"><b>$($data.total)</b><span>เคสทั้งหมด</span></div>
    <div class="stat pass"><b>$($data.pass)</b><span>ผ่าน</span></div>
    <div class="stat fail"><b>$($data.fail)</b><span>ไม่ผ่าน</span></div>
    <div class="stat planned"><b>$($data.planned)</b><span>ข้าม (planned)</span></div>
  </div>

  <div class="bar" id="verdicts">
    <button class="chip" data-v="ALL" aria-pressed="true">ทั้งหมด</button>
    <button class="chip" data-v="PASS" aria-pressed="false">ผ่าน</button>
    <button class="chip" data-v="FAIL" aria-pressed="false">ไม่ผ่าน</button>
    <button class="chip" data-v="PLANNED" aria-pressed="false">ข้าม (planned)</button>
  </div>
  <div class="bar">
    <button class="chip" data-file="ALL" aria-pressed="true">ทุกไฟล์</button>
$(($files | ForEach-Object { "    <button class=`"chip`" data-file=`"$_`" aria-pressed=`"false`">$_</button>" }) -join "`n")
    <span class="spacer"></span>
    <input type="search" id="q" placeholder="ค้นหาด้วย id, ชื่อ หรือ URL" autocomplete="off">
  </div>

  <div class="head">
    <span></span><span>id</span><span>ชื่อเทสต์</span>
    <span class="num hide">สถานะ</span><span class="num hide">ขนาด</span><span class="num">มิลลิวินาที</span>
  </div>
  <div id="list"></div>
  <div class="empty" id="empty" hidden>ไม่พบเคสที่ตรงกับตัวกรอง</div>

  <footer>
    สร้างโดย <code class="k">scripts\New-Dashboard.ps1</code> จาก <code class="k">evidence\results.json</code><br>
    คลิกแถวเพื่อดู URL, เหตุผล และลิงก์ไปยังไฟล์หลักฐาน
  </footer>
</div>

<script>
const DATA = $jsonForHtml;
const PALETTE = {
  PASS:    { cls: 'pass',    label: 'ผ่าน' },
  FAIL:    { cls: 'fail',    label: 'ไม่ผ่าน' },
  PLANNED: { cls: 'planned', label: 'ข้าม (planned)' },
  SKIP:    { cls: 'planned', label: 'ข้าม' }
};

const list = document.getElementById('list');
const empty = document.getElementById('empty');
const q = document.getElementById('q');
let verdict = 'ALL', file = 'ALL';

const esc = s => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function bytes(n) {
  if (!n) return '-';
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}

// Id เก็บทั้งรหัสและชื่อไว้ในบรรทัดเดียว เช่น "SQLI-03 UNION based - 5 columns"
// แยกออกเป็นรหัสกับชื่อเพื่อแสดงคนละคอลัมน์
function splitId(raw) {
  const m = /^([A-Z]{2,}-\d+)\s*(.*)$/.exec(String(raw || ''));
  return m ? { code: m[1], title: m[2] || raw } : { code: '', title: raw || '' };
}

function matches(r) {
  if (verdict !== 'ALL' && r.Verdict !== verdict) return false;
  if (file !== 'ALL' && r.File !== file) return false;
  const term = q.value.trim().toLowerCase();
  if (!term) return true;
  return [r.Id, r.File, r.Url, r.Note, r.Reason]
    .some(v => String(v || '').toLowerCase().includes(term));
}

function detail(r) {
  const p = PALETTE[r.Verdict] || PALETTE.SKIP;
  let html = '<dl>';
  if (r.Method) html += '<dt>วิธี</dt><dd><code>' + esc(r.Method) + '</code></dd>';
  if (r.Url)    html += '<dt>URL</dt><dd><code>' + esc(r.Url) + '</code></dd>';
  if (r.Note) {
    const bad = r.Verdict === 'FAIL';
    html += '<dt>' + (bad ? 'ไม่ผ่านเพราะ</dt><dd class="why failed">' : 'เหตุผล</dt><dd class="why">')
          + esc(r.Note).replace(/\n/g, '<br>') + '</dd>';
  }
  if (r.Evidence) html += '<dt>หลักฐาน</dt><dd><a href="evidence/' + esc(r.Evidence) + '">evidence/'
                          + esc(r.Evidence) + '</a></dd>';
  return html + '</dl>';
}

function render() {
  const rows = DATA.results.filter(matches);
  empty.hidden = rows.length > 0;
  list.innerHTML = rows.map((r, i) => {
    const p = PALETTE[r.Verdict] || PALETTE.SKIP;
    const s = splitId(r.Id);
    return '<div class="row ' + p.cls + '" data-i="' + i + '" role="button" tabindex="0"'
         + ' title="' + esc(s.title) + '">'
         + '<span class="dot ' + p.cls + '"></span>'
         + '<span class="id">' + esc(s.code) + '</span>'
         + '<span class="name">' + esc(s.title) + '</span>'
         + '<span class="num hide">' + esc(r.Status) + '</span>'
         + '<span class="num hide">' + bytes(r.Bytes) + '</span>'
         + '<span class="num">' + (r.Ms || '-') + '</span>'
         + '</div><div class="detail">' + detail(r) + '</div>';
  }).join('');
}

list.addEventListener('click', e => {
  const row = e.target.closest('.row');
  if (!row) return;
  row.classList.toggle('open');
});
list.addEventListener('keydown', e => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  const row = e.target.closest('.row');
  if (row) { e.preventDefault(); row.classList.toggle('open'); }
});

function wire(sel, attr, set) {
  document.querySelectorAll(sel).forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll(sel).forEach(b => b.setAttribute('aria-pressed', 'false'));
      btn.setAttribute('aria-pressed', 'true');
      set(btn.dataset[attr]);
      render();
    });
  });
}
wire('#verdicts .chip', 'v', v => verdict = v);
wire('.bar .chip[data-file]', 'file', f => file = f);
q.addEventListener('input', render);

render();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "สร้าง dashboard แล้ว: $OutFile  ($($data.total) เคส, ผ่าน $($data.pass), ไม่ผ่าน $($data.fail), ข้าม $($data.planned))"
Write-Output "เปิดด้วย double-click ที่ไฟล์ หรือพิมพ์: start `"$OutFile`""
