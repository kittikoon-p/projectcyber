// ใช้ headless Chrome ทดสอบว่าตัวกรองและช่องค้นหาทำงานจริงใน DOM จริง
// วิธี: คัดลอก dashboard.html แล้วเติมสคริปต์ที่คลิกแท่ปแต่ละอันแล้วบันทึกผลลง <title>
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(ROOT, 'dashboard.html'), 'utf8');
const tmp = path.join(require('os').tmpdir(), 'opencode', 'shot', 'probe.html');
fs.mkdirSync(path.dirname(tmp), { recursive: true });

const probe = `
<script>
// ห้ามประกาศชื่อตัวแปรซ้ำกับสคริปต์หลัก (const ที่ระดับ top-level ของ classic script
// ใช้ global lexical scope ร่วมกัน) ไม่งั้น SyntaxError จะทำให้ทั้งสคริปต์ไม่รัน
const tCount = () => document.querySelectorAll('.row').length;
const tClick = sel => document.querySelector(sel).click();
const log = [];

log.push('init=' + tCount());

// ตัวกรองตามผล
tClick('[data-v="PASS"]');    log.push('pass=' + tCount());
tClick('[data-v="FAIL"]');    log.push('fail=' + tCount());
tClick('[data-v="PLANNED"]'); log.push('planned=' + tCount());
tClick('[data-v="ALL"]');     log.push('all=' + tCount());

// ตัวกรองตามไฟล์ แล้วดูว่าไม่มี id หลุดออกมา
const tChips = [...document.querySelectorAll('.chip[data-file]')].filter(b => b.dataset.file !== 'ALL');
let sum = 0; const bad = [];
for (const c of tChips) {
  c.click();
  const n = tCount();
  sum += n;
  const f = c.dataset.file;
  const rows = [...document.querySelectorAll('.row .id')].map(e => e.textContent);
  if (!rows.length) bad.push(f + ':0');
  if (rows.some(t => !t.trim())) bad.push(f + ':blank');
}
log.push('fileSum=' + sum);
log.push('blankId=' + (bad.length ? bad.join(',') : 'none'));

// ค้นหา
tClick('[data-file="ALL"]');
const tBox = document.getElementById('q');
tBox.value = 'SQLI'; tBox.dispatchEvent(new Event('input'));
log.push('searchSQLI=' + tCount());
tBox.value = 'zzzznope'; tBox.dispatchEvent(new Event('input'));
log.push('searchNone=' + tCount() + '/empty=' + !document.getElementById('empty').hidden);
tBox.value = ''; tBox.dispatchEvent(new Event('input'));
log.push('searchReset=' + tCount());

// กดแถวเพื่อกางแผงรายละเอียด
document.querySelector('.row').click();
log.push('open=' + document.querySelectorAll('.row.open').length);
document.querySelector('.row').click();
log.push('close=' + document.querySelectorAll('.row.open').length);

document.title = 'R' + log.join('|') + 'R';
</script>
`;
fs.writeFileSync(tmp, src.replace('</body>', probe + '</body>'), 'utf8');

const chrome = process.env.CHROME ||
  'C:\\\\Program Files\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe';
const out = execFileSync(chrome, [
  '--headless=new', '--disable-gpu', '--virtual-time-budget=6000', '--dump-dom',
  'file:///' + tmp.replace(/\\/g, '/')
], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });

const title = /<title>(.*?)<\/title>/s.exec(out);
if (!title) { console.error('FAIL: ไม่พบ title'); process.exit(1); }
const raw = title[1].replace(/^R/, '').replace(/R$/, '');
console.log(raw);

// ค่าบางตัวมี "=" อยู่ในตัวค่นเอง (เช่น searchNone=0/empty=true) จึงต้องตัดที่ "=" แรกเท่านั้น
const got = Object.fromEntries(raw.split('|').map(s => {
  const i = s.indexOf('=');
  return [s.slice(0, i), s.slice(i + 1)];
}));

// ค่าที่คาดหวังต้องคำนวณจากข้อมูลจริง ไม่เดายอดตัวเลข
const DATA = JSON.parse(/const DATA = (.*?);\r?\nconst PALETTE/s.exec(
  fs.readFileSync(path.join(ROOT, 'dashboard.html'), 'utf8'))[1].replace(/\\u003c/g, '<'));
const R = DATA.results;
const tally = v => R.filter(r => v === 'ALL' || r.Verdict === v).length;
const hit = term => R.filter(r => [r.Id, r.File, r.Url, r.Note, r.Reason]
  .some(v => String(v || '').toLowerCase().includes(term))).length;
const nFiles = [...new Set(R.map(r => r.File))].length;

const want = {
  init: R.length, all: R.length,
  pass: tally('PASS'), fail: tally('FAIL'), planned: tally('PLANNED') + tally('SKIP'),
  fileSum: R.length, blankId: 'none',
  searchSQLI: hit('sqli'), searchReset: R.length,
  open: '1', close: '0'
};
let bad = 0;
for (const [k, v] of Object.entries(want)) {
  if (got[k] !== String(v)) { console.error(`FAIL: ${k} ได้ ${got[k]} คาดว่า ${v}`); bad++; }
}
if (got.searchNone !== '0/empty=true') { console.error(`FAIL: searchNone ได้ "${got.searchNone}"`); bad++; }
if (nFiles !== 10) { console.error(`FAIL: จำนวนไฟล์ ${nFiles} คาดว่า 10`); bad++; }
console.log(bad ? `ผิดพลาด ${bad} รายการ` : 'ผ่านทั้งหมด');
process.exit(bad ? 1 : 0);
