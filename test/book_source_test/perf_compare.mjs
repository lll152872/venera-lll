// 漫蛙吧优化前后性能对比（同一部漫画，同一网络环境）
// 旧逻辑：详情串行 + pageSize=1 探测 + 按 100 分页串行
// 新逻辑：详情与章节并发 + pageSize=500 一次拉全（不够才并发补页）
import fs from 'node:fs';
import vm from 'node:vm';

const API = 'https://manwari.cc/api';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120';
const COMIC_ID = '6566';   // 海贼王，396 章节（扫描 1-120 外的最长之一）

let reqCount = 0;
async function get(url) {
  reqCount++;
  const r = await fetch(url, { headers: { 'user-agent': UA } });
  return await r.json();
}

// ---------- 旧逻辑 ----------
async function loadInfoOld(id) {
  const data = (await get(`${API}/comic/${id}`)).data;
  const chapterApi = `${API}/comic/chapter`;
  const first = await get(`${chapterApi}?comicId=${data.id}&page=1&pageSize=1`);
  const total = first.pagination.total;
  const chapters = new Map();
  const pageSize = 100;
  const pages = Math.ceil(total / pageSize);
  for (let p = 1; p <= pages; p++) {
    const r = await get(`${chapterApi}?comicId=${data.id}&page=${p}&pageSize=${pageSize}`);
    for (const item of r.data) chapters.set(item.id.toString(), item.title.toString());
  }
  return chapters;
}

async function loadEpOld(epId) {
  const imgApi = `${API}/comic/image/${epId}`;
  const qs = `image_source=${encodeURIComponent('https://tu.mhttu.cc')}`;
  const first = await get(`${imgApi}?${qs}&page=1&page_size=1`);
  const total = first.data.pagination.total;
  const images = [];
  const pageSize = 50;
  const pages = Math.ceil(total / pageSize);
  for (let p = 1; p <= pages; p++) {
    const r = await get(`${imgApi}?${qs}&page=${p}&page_size=${pageSize}`);
    for (const it of r.data.images) images.push(it.url);
  }
  return images;
}

// ---------- 新逻辑：直接跑书源代码 ----------
function buildSource() {
  const SRC = fs.readFileSync('D:/mycode/venera/book source/manwaba.js', 'utf8');
  class ComicSource {}
  class Comic { constructor(o) { Object.assign(this, o); } }
  class ComicDetails { constructor(o) { Object.assign(this, o); } }
  const Network = {
    async sendRequest(method, url, headers, data) {
      reqCount++;
      const init = { method, headers: { 'user-agent': UA, ...(headers || {}) } };
      if (data != null && method !== 'GET') init.body = data;
      const r = await fetch(url, init);
      return { status: r.status, body: await r.text() };
    },
  };
  const ctx = { ComicSource, Comic, ComicDetails, Network, console, log: () => {}, error: console.error, APP: { version: '2.0.0' }, setTimeout, fetch };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  new vm.Script(SRC + '\n;globalThis.__I = ManWaBa;').runInContext(ctx);
  const inst = new ctx.__I();
  inst.init();
  return inst;
}

async function timed(label, fn) {
  reqCount = 0;
  const t0 = Date.now();
  const r = await fn();
  const ms = Date.now() - t0;
  return { label, ms, reqs: reqCount, r };
}

console.log(`测试对象：comicId=${COMIC_ID}（海贼王）\n`);

// 预热（排除首次 TLS / DNS 影响，两边都预热）
await timed('warmup', () => get(`${API}/comic/1`));

const oldInfo = await timed('loadInfo 旧', () => loadInfoOld(COMIC_ID));
const newInfo = await timed('loadInfo 新', async () => (await buildSource().comic.loadInfo(COMIC_ID)).chapters);

// 取同一个章节测 loadEp
const epId = mapFirstKey(newInfo.r);
console.log(`取章节 epId=${epId} 做 loadEp 对比\n`);

const oldEp = await timed('loadEp 旧', () => loadEpOld(epId));
const newEp = await timed('loadEp 新', () => buildSource().comic.loadEp(COMIC_ID, epId));

function mapFirstKey(m) { let k = null; m.forEach((_v, key) => { if (k === null) k = key; }); return k; }

const rows = [
  ['loadInfo', oldInfo, newInfo, oldInfo.r.size, newInfo.r.size],
  ['loadEp', oldEp, newEp, oldEp.r.length, (newEp.r.images || []).length],
];
const pad = (s, n) => String(s).padStart(n);
const padE = (s, n) => String(s).padEnd(n);
console.log(padE('环节', 10) + pad('旧耗时', 10) + pad('新耗时', 10) + pad('旧请求', 9) + pad('新请求', 9) + pad('旧结果', 10) + pad('新结果', 10));
console.log('-'.repeat(68));
for (const [name, o, n, oc, nc] of rows) {
  console.log(padE(name, 10) + pad(o.ms + 'ms', 10) + pad(n.ms + 'ms', 10) + pad(o.reqs, 9) + pad(n.reqs, 9) + pad(oc, 10) + pad(nc, 10));
}
console.log('-'.repeat(68));
const oT = oldInfo.ms + oldEp.ms, nT = newInfo.ms + newEp.ms;
const oR = oldInfo.reqs + oldEp.reqs, nR = newInfo.reqs + newEp.reqs;
console.log(padE('合计', 10) + pad(oT + 'ms', 10) + pad(nT + 'ms', 10) + pad(oR, 9) + pad(nR, 9));
console.log('\n提速 %.2fx，请求数 %d → %d（减少 %.0f%%）'
  .replace('%.2fx', (oT / nT).toFixed(2) + 'x')
  .replace('%d', oR).replace('%d', nR)
  .replace('%.0f%%', ((1 - nR / oR) * 100).toFixed(0) + '%'));
