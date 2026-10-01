const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'dashboard.html'), 'utf8');

const m = /const DATA = (.*?);\r?\nconst PALETTE/s.exec(html);
if (!m) { console.error('FAIL: ไม่พบ DATA'); process.exit(1); }
const DATA = JSON.parse(m[1].replace(/\\u003c/g, '<'));

const PALETTE = {
  PASS: { cls: 'pass' }, FAIL: { cls: 'fail' },
  PLANNED: { cls: 'planned' }, SKIP: { cls: 'planned' }
};
const esc = s => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
function bytes(n) {
  if (!n) return '-';
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}
function splitId(raw) {
  const r = /^([A-Z]{2,}-\d+)\s*(.*)$/.exec(String(raw || ''));
  return r ? { code: r[1], title: r[2] || raw } : { code: '', title: raw || '' };
}

let fail = 0;
const bad = (msg) => { console.error('FAIL: ' + msg); fail++; };

// 1. นับผลรวมตรงกับ results
for (const k of ['pass', 'fail', 'planned']) {
  const actual = DATA.results.filter(r => k === 'planned'
    ? ['PLANNED', 'SKIP'].includes(r.Verdict) : r.Verdict === k.toUpperCase()).length;
  if (actual !== DATA[k]) bad(`${k}: header=${DATA[k]} แต่นับจริงได้ ${actual}`);
}
if (DATA.results.length !== DATA.total) bad('total ไม่ตรงกับจำนวนแถว');

// 2. ทุกเคสต้องมีรหัสและชื่อที่แยกได้
let noCode = 0;
for (const r of DATA.results) {
  const s = splitId(r.Id);
  if (!s.code) noCode++;
  if (!s.title) bad(`ไม่มีชื่อเทสต์: ${r.Id}`);
  if (!PALETTE[r.Verdict]) bad(`ไม่รู้จัก Verdict: ${r.Verdict}`);
}
if (noCode) bad(`${noCode} เคสไม่มีรหัสแบบ XX-00`);

// 3. ลิงก์หลักฐานต้องมีไฟล์จริง และชื่อไฟล์ต้องปลอดภัย
let links = 0;
for (const r of DATA.results) {
  if (!r.Evidence) {
    if (r.Verdict === 'PASS' || r.Verdict === 'FAIL') bad(`เคส ${r.Id} ไม่มีลิงก์หลักฐาน`);
    continue;
  }
  links++;
  if (!/^[\w.-]+$/.test(r.Evidence)) bad(`ชื่อไฟล์หลักฐานไม่ปลอดภัย: ${r.Evidence}`);
  if (!fs.existsSync(path.join(ROOT, 'evidence', r.Evidence))) bad(`ไม่พบไฟล์: evidence/${r.Evidence}`);
}
const onDisk = fs.readdirSync(path.join(ROOT, 'evidence')).filter(f => f.endsWith('.txt')).length;
if (links !== onDisk) bad(`ลิงก์ ${links} แต่มีไฟล์ .txt บนดิสก์ ${onDisk}`);

// 4. ตัวกรองต้องได้ผลตรงกับตัวเลขบนหน้าเว็บ
const tests = [
  ['ALL', 'ALL', DATA.total],
  ['PASS', 'ALL', DATA.pass],
  ['FAIL', 'ALL', DATA.fail],
  ['PLANNED', 'ALL', DATA.planned]
];
const files = [...new Set(DATA.results.map(r => r.File))].sort();
for (const f of files) {
  tests.push(['ALL', f, DATA.results.filter(r => r.File === f).length]);
}
for (const [v, f, want] of tests) {
  const got = DATA.results.filter(r =>
    (v === 'ALL' || r.Verdict === v) && (f === 'ALL' || r.File === f)).length;
  if (got !== want) bad(`ตัวกรอง ${v}/${f}: ได้ ${got} คาดว่า ${want}`);
}
// ไม่มีผลรวมของไฟล์ไหนหลุดหายไป
const sumFiles = files.reduce((a, f) => a + DATA.results.filter(r => r.File === f).length, 0);
if (sumFiles !== DATA.total) bad(`ผลรวมตามไฟล์ ${sumFiles} != total ${DATA.total}`);

// 5. ค้นหาต้องเจอทุกคำใน id และไฟล์
for (const r of DATA.results.slice(0, 40)) {
  const term = String(r.Id).split(' ')[0].toLowerCase();
  const got = DATA.results.filter(x => String(x.Id).toLowerCase().includes(term)).length;
  if (got < 1) bad(`ค้นหา '${term}' ไม่พบผลลัพธ์`);
}

// 6. esc ต้องกัน HTML injection ได้จริง
const nasty = `<img src=x onerror=alert(1)>"O'Brien`;
const out = esc(nasty);
if (out.includes('<img') || out.includes('"')) bad('esc ไม่ได้ escape แท็กที่อันตราย');
if (esc('<') !== '&lt;') bad('esc < ไม่ถูกต้อง');

// 7. bytes() ต้องไม่คืนค่าว่าง
for (const n of [0, 512, 2048, 1048576 * 3]) {
  if (!bytes(n)) bad(`bytes(${n}) ว่างเปล่า`);
}

// 8. ตรวจว่าไม่มี </script> หลุดออกมาใน DATA
if (m[1].includes('</script>')) bad('DATA หลุด </script> ออกมา');
if (/const DATA = .*?<\/script>/s.test(html) === false) bad('ไม่พบแท็กปิด script ของ DATA');

console.log(`ผลการทดสอบ: ${fail === 0 ? 'ผ่านทั้งหมด' : fail + ' รายการผิดพลาด'}`);
console.log(`  เคส ${DATA.total} | ไฟล์ ${files.length} | ลิงก์หลักฐาน ${links} | ไฟล์บนดิสก์ ${onDisk}`);
process.exit(fail ? 1 : 0);
