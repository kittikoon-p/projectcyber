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

# ความกว้างแต่ละส่วนของแถบสรุปเป็น % - เหลือส่วนท้ายให้ planned เสมอ
# เพื่อให้ผลรวมกว้างเต็มแถบเสมอ ไม่ขึ้นกับปัดเศษทศนิยม
$total = [double]$data.total
$pctPass = if ($total) { [math]::Round($data.pass * 100 / $total, 3) } else { 0 }
$pctFail = if ($total) { [math]::Round($data.fail * 100 / $total, 3) } else { 0 }
$pctPlanned = [math]::Round(100 - $pctPass - $pctFail, 3)

$html = @"
<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>bWAPP - ผลการทดสอบความปลอดภัย</title>
<style>
  :root {
    --bg: #0a0d13;
    --panel: #12161f;
    --line: #1c2230;
    --text: #e8eef6;
    --dim: #79828f;
    --faint: #4f5763;
    --pass: #3fb950;
    --fail: #f85149;
    --planned: #d29922;
    --accent: #7aa2f7;
    --mono: ui-monospace, SFMono-Regular, "Cascadia Code", Consolas, monospace;
    --ease: cubic-bezier(0.2, 0, 0.2, 1);
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; scrollbar-color: #232a36 var(--bg); }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 13.5px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans Thai", "Leelawadee UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  /* แสงเรืองจางมากด้านบน กันพื้นหลังแบนจนดูแข็งและไม่เหนื่อยตา */
  body::before {
    content: ""; position: fixed; inset: 0 0 auto; height: 340px; pointer-events: none;
    background: radial-gradient(70% 100% at 50% 0, rgba(122, 162, 247, 0.07), transparent 72%);
  }
  ::selection { background: rgba(122, 162, 247, 0.3); }
  .wrap { max-width: 880px; margin: 0 auto; padding: 64px 24px 96px; }

  /* หัวเรื่อง - บรรทัดเดียว ไม่มีกล่อง */
  header { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  h1 { margin: 0; font-size: 14px; font-weight: 600; letter-spacing: 0.02em; }
  h1 span { color: var(--dim); font-weight: 400; }
  .sub { margin-left: auto; color: var(--faint); font-size: 11.5px; font-family: var(--mono); }

  /* แถบสัดส่วนผล + ตัวเลขสรุป */
  .meter { display: flex; height: 2px; margin-top: 24px; border-radius: 2px; overflow: hidden; background: var(--line); }
  .meter i { display: block; height: 100%; }
  .meter i.pass { background: var(--pass); }
  .meter i.fail { background: var(--fail); }
  .meter i.planned { background: var(--planned); }
  .tally { display: flex; gap: 18px; flex-wrap: wrap; margin: 11px 0 34px; font-size: 12px; color: var(--faint); }
  .tally b { color: var(--dim); font-weight: 600; font-variant-numeric: tabular-nums; }
  .tally .pass b { color: var(--pass); }
  .tally .fail b { color: var(--fail); }
  .tally .planned b { color: var(--planned); }

  /* ตัวกรองกับหัวตารางตรึงไว้บนจอ ตัวกรอง 122 แถวแล้วไม่ต้องเลื่อนขึ้นมาหาใหม่ */
  .panel { position: sticky; top: 0; z-index: 5; background: var(--bg); padding-top: 12px; }

  /* แถบควบคุม - ปุ่มไร้กรอบ ตัวอักษรเล็ก */
  .filters { display: flex; gap: 18px; align-items: center; flex-wrap: wrap; padding-bottom: 14px; }
  .grp { display: flex; gap: 2px; flex-wrap: wrap; }
  .chip {
    padding: 3px 9px; border: 0; border-radius: 6px; background: transparent;
    color: var(--faint); cursor: pointer; font: inherit; font-size: 12px; white-space: nowrap;
    transition: color 0.13s var(--ease), background-color 0.13s var(--ease);
  }
  .chip:hover { color: var(--text); background: var(--panel); }
  .chip[aria-pressed="true"] { color: var(--text); background: var(--panel); box-shadow: inset 0 0 0 1px var(--line); }
  input[type=search] {
    margin-left: auto; min-width: 200px; padding: 5px 10px 5px 28px;
    background: var(--panel) no-repeat 9px center / 13px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='%234f5763' stroke-width='1.6' stroke-linecap='round'%3E%3Ccircle cx='7' cy='7' r='4.5'/%3E%3Cpath d='M10.4 10.4 14 14'/%3E%3C/svg%3E");
    color: var(--text); border: 1px solid transparent; border-radius: 7px;
    font: inherit; font-size: 12px; transition: border-color 0.13s var(--ease);
  }
  input[type=search]::-webkit-search-cancel-button { filter: grayscale(1) opacity(0.5); }
  input[type=search]::placeholder { color: var(--faint); }
  input[type=search]:focus { outline: none; border-color: var(--accent); }

  /* หัวตาราง */
  .head, .row {
    display: grid;
    grid-template-columns: 12px 78px 1fr 42px 46px;
    gap: 12px; align-items: center;
  }
  .head {
    padding: 0 6px 8px; color: var(--faint);
    font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.08em;
    border-bottom: 1px solid var(--line);
  }
  .head .num, .row .num { text-align: right; font-family: var(--mono); font-variant-numeric: tabular-nums; font-size: 11.5px; color: var(--faint); }

  /* แถวผลการทดสอบ - เส้นคั่นบาง ไม่มีกล่อง */
  .row {
    padding: 7px 6px; border-bottom: 1px solid rgba(255, 255, 255, 0.03); cursor: pointer;
    transition: background-color 0.13s var(--ease);
  }
  .row:hover { background: var(--panel); }
  .row.open { background: var(--panel); box-shadow: inset 2px 0 0 var(--accent); }
  .dot { width: 5px; height: 5px; border-radius: 50%; justify-self: center; }
  .dot.pass { background: var(--pass); }
  .dot.fail { background: var(--fail); }
  .dot.planned { background: var(--planned); }
  /* รหัสเทสต์ 122 บรรทัดถ้าสีฟ้าทั้งหมดจะรกสายตา - จังหวะสีให้ตอน hover หรือตอนกางเท่านั้น */
  .id { font-family: var(--mono); font-size: 11.5px; color: var(--faint); letter-spacing: -0.01em; transition: color 0.13s var(--ease); }
  .row:hover .id, .row.open .id { color: var(--accent); }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row.fail .name { color: var(--fail); }
  .row.planned .name { color: var(--dim); }

  /* แผงรายละเอียดเมื่อกดแถว */
  .detail { display: none; padding: 1px 6px 15px 30px; }
  .row.open + .detail { display: block; }
  .detail dl { display: grid; grid-template-columns: 62px 1fr; gap: 5px 12px; margin: 0; }
  .detail dt { color: var(--faint); font-size: 11.5px; }
  .detail dd { margin: 0; font-size: 12.5px; word-break: break-word; }
  .detail code {
    font: 11.5px/1.5 var(--mono);
    background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px;
  }
  .why { color: var(--planned); }
  .why.failed { color: var(--fail); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .empty { padding: 48px 6px; text-align: center; color: var(--faint); }
  footer { margin-top: 32px; color: var(--faint); font-size: 11.5px; }
  code.k { font-family: var(--mono); color: var(--dim); }

  /* วงแหวนโฟกัสสำหรับผู้ใช้คีย์บอร์ด แต่ไม่โผล่ตอนคลิกเมาส์ */
  .chip:focus-visible, .row:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .row:focus-visible { border-radius: 4px; }

  @media (max-width: 680px) {
    /* ซ่อนคอลัมน์สถานะแล้วเหลือ 4 ช่อง - จึงต้องมี grid 4 คอลัมน์ให้ตรงกัน
       ไม่งั้นช่องสุดท้ายจะล้มไปตกแถวใหม่แล้วหัวตารางจะเลื่อนไม่ตรงแถว */
    .panel { position: static; }
    .head, .row { grid-template-columns: 12px 66px 1fr 46px; }
    .hide { display: none; }
    .name { white-space: normal; overflow: visible; }
    .detail { padding-left: 6px; }
  }
  @media (prefers-reduced-motion: reduce) {
    * { transition: none !important; }
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>bWAPP <span>ผลการทดสอบความปลอดภัย</span></h1>
    <div class="sub">$($data.generated) &middot; $($data.baseUrl)</div>
  </header>

  <div class="meter">
    <i class="pass" style="width:$pctPass%"></i>
    <i class="fail" style="width:$pctFail%"></i>
    <i class="planned" style="width:$pctPlanned%"></i>
  </div>
  <div class="tally">
    <span><b>$($data.total)</b> เคส</span>
    <span class="pass"><b>$($data.pass)</b> ผ่าน</span>
    <span class="fail"><b>$($data.fail)</b> ไม่ผ่าน</span>
    <span class="planned"><b>$($data.planned)</b> ข้าม</span>
  </div>

  <div class="panel">
    <div class="filters">
      <div class="grp" id="verdicts">
        <button class="chip" data-v="ALL" aria-pressed="true">ทั้งหมด</button>
        <button class="chip" data-v="PASS" aria-pressed="false">ผ่าน</button>
        <button class="chip" data-v="FAIL" aria-pressed="false">ไม่ผ่าน</button>
        <button class="chip" data-v="PLANNED" aria-pressed="false">ข้าม</button>
      </div>
      <div class="grp">
        <button class="chip" data-file="ALL" aria-pressed="true">ทุกไฟล์</button>
$(($files | ForEach-Object { "        <button class=`"chip`" data-file=`"$_`" aria-pressed=`"false`">$_</button>" }) -join "`n")
      </div>
      <input type="search" id="q" placeholder="ค้นหา id, ชื่อ หรือ URL" autocomplete="off">
    </div>

    <div class="head">
      <span></span><span>id</span><span>ชื่อเทสต์</span>
      <span class="num hide">สถานะ</span><span class="num" title="มิลลิวินาที">ms</span>
    </div>
  </div>
  <div id="list"></div>
  <div class="empty" id="empty" hidden>ไม่พบเคสที่ตรงกับตัวกรอง</div>

  <footer>คลิกแถวเพื่อดู URL, เหตุผล และลิงก์ไปยังไฟล์หลักฐาน &middot; สร้างโดย <code class="k">scripts\New-Dashboard.ps1</code></footer>
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
  let html = '<dl>';
  if (r.Method) html += '<dt>วิธี</dt><dd><code>' + esc(r.Method) + '</code></dd>';
  if (r.Url)    html += '<dt>URL</dt><dd><code>' + esc(r.Url) + '</code></dd>';
  html += '<dt>ผลลัพธ์</dt><dd><code>' + esc(r.Status) + '</code> &middot; ' + bytes(r.Bytes)
        + ' &middot; ' + (r.Ms || '-') + ' ms</dd>';
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
         + '<span class="dot ' + p.cls + '" aria-label="' + esc(p.label) + '"></span>'
         + '<span class="id">' + esc(s.code) + '</span>'
         + '<span class="name">' + esc(s.title) + '</span>'
         + '<span class="num hide">' + esc(r.Status) + '</span>'
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
wire('.chip[data-file]', 'file', f => file = f);
q.addEventListener('input', render);

render();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "สร้าง dashboard แล้ว: $OutFile  ($($data.total) เคส, ผ่าน $($data.pass), ไม่ผ่าน $($data.fail), ข้าม $($data.planned))"
Write-Output "เปิดด้วย double-click ที่ไฟล์ หรือพิมพ์: start `"$OutFile`""
