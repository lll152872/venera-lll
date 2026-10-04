// 分类页联调测试：验证「点第 N 个分类项能否真加载漫画」
//
// 存在的理由：book_source_test.mjs 只验 categoryComics.load 存不存在，
// 不验 category 对象结构，也不验点具体分类项能否加载。
// 2026-10-04 就因为两个新源的 category 结构写错（缺 title/itemType），
// 测试显示 14/14 全通过，但 App 分类页一个分类都不显示。
//
// 用法： node cat_test.mjs <书源.js 路径>
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import * as cheerio from 'cheerio';

const src = process.argv[2];
if (!src) { console.error('用法: node cat_test.mjs <书源.js>'); process.exit(1); }
const code = fs.readFileSync(src, 'utf8');

// ---- 运行时全局对象（对齐 book_source_test.mjs 的 mock）----
class ComicSource {
  #s = {};
  loadData(k) { return this.#s[k] ?? null; }
  saveData(k, v) { this.#s[k] = v; }
  loadSetting(k) { return this.settings?.[k]?.default ?? null; }
}
class Comic { constructor(o) { Object.assign(this, o); } }
class ComicDetails { constructor(o) { Object.assign(this, o); } }

// ⚠️ querySelectorAll 必须返回**真数组**（length + 数字下标）。
// 书源里写 `for (let a of doc.querySelectorAll('a'))`，返回迭代器/包装对象会死循环。
function makeHtmlDocument(html) {
  const $ = cheerio.load(html);
  function wrapOne(node) {
    const $n = $(node);
    return {
      get text() { return $n.text(); },
      get innerHTML() { return $n.html() || ''; },
      attributes: node.attribs || {},
      querySelector(sel) { const f = $n.find(sel).first(); return f.length ? wrapOne(f[0]) : null; },
      querySelectorAll(sel) { const out = []; $n.find(sel).each(function () { out.push(wrapOne(this)); }); return out; },
      get childNodes() { const out = []; $n.contents().each(function () { out.push($(this).text()); }); return out; },
    };
  }
  return {
    querySelector(sel) { const f = $('body').find(sel).first(); return f.length ? wrapOne(f[0]) : null; },
    querySelectorAll(sel) { const out = []; $('body').find(sel).each(function () { out.push(wrapOne(this)); }); return out; },
  };
}
class HtmlDocument { constructor(html) { return makeHtmlDocument(html); } }

function clean(h) {
  const o = {};
  for (const [k, v] of Object.entries(h || {})) if (v != null) o[k] = v;
  return o;
}
// ⚠️ App 的 Network.get 返回 {status, body}，书源判断 res.status，不是 statusCode。
const Network = {
  async get(u, o) {
    const r = await fetch(String(u), { headers: clean((o && o.headers) || o), redirect: 'follow' });
    const t = await r.text();
    return { status: r.status, statusCode: r.status, body: t, headers: Object.fromEntries(r.headers.entries()) };
  },
  async post(u, d, o) {
    const r = await fetch(String(u), { method: 'POST', body: typeof d === 'string' ? d : JSON.stringify(d), redirect: 'follow' });
    const t = await r.text();
    return { status: r.status, statusCode: r.status, body: t };
  },
  async fetchBytes(u, o) {
    const r = await fetch(String(u), { redirect: 'follow' });
    return { status: r.status, statusCode: r.status, body: await r.arrayBuffer() };
  },
  async getCookies() { return ''; },
  async setCookies() {},
  // 签名对齐 assets/init.js:498 —— sendRequest(method, url, headers, data, extra)
  async sendRequest(method, url, headers, data, extra) {
    const r = await fetch(String(url), {
      method: method || 'GET',
      headers: clean(headers),
      body: data != null ? (typeof data === 'string' ? data : JSON.stringify(data)) : undefined,
      redirect: 'follow',
    });
    const t = await r.text();
    return { status: r.status, statusCode: r.status, body: t, headers: Object.fromEntries(r.headers.entries()) };
  },
};

const ctx = {
  ComicSource, Comic, ComicDetails, Network, HtmlDocument,
  console, fetch, setTimeout, clearTimeout, setInterval, clearInterval,
  Date, Math, JSON, Promise, Uint8Array, ArrayBuffer, URL, URLSearchParams,
  encodeURIComponent, decodeURIComponent, parseInt, parseFloat, isNaN, isFinite,
  Buffer, atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
  btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
};
ctx.globalThis = ctx;
ctx.self = ctx;
vm.createContext(ctx);

const clsName = (code.match(/class\s+(\w+)\s+extends\s+ComicSource/) || [])[1];
if (!clsName) { console.log('❌ 未找到 class Xxx extends ComicSource'); process.exit(1); }
// class 声明在 vm 作用域内不挂到 ctx，必须同段代码显式导出
vm.runInContext(code + '\n;globalThis.__Cls = ' + clsName + ';', ctx, { filename: path.basename(src) });

const inst = new ctx.__Cls();
try { await inst.init?.(); } catch (e) { console.log('⚠️ init() 失败（不阻塞分类测试）:', e?.message || e); }

console.log(`\n=== ${inst.name} (${inst.key}) 分类页联调 ===`);
const cat = inst.category;
if (!cat || typeof cat !== 'object') { console.log('❌ 无 category 对象'); process.exit(1); }
if (typeof cat.title !== 'string' || !cat.title) {
  console.log('❌ category.title 缺失 → App 的 _loadCategoryData() 会 return null，分类页看不到本源');
  process.exit(1);
}
if (!Array.isArray(cat.parts) || !cat.parts.length) { console.log('❌ category.parts 为空'); process.exit(1); }

const p0 = cat.parts[0];
const cats = Array.isArray(p0.categories) ? p0.categories : [];
const params = Array.isArray(p0.categoryParams) ? p0.categoryParams : null;
console.log(`category.title="${cat.title}"  parts=${cat.parts.length}  分类项=${cats.length}`);
console.log(`part[0]: name="${p0.name}" type="${p0.type}" itemType="${p0.itemType}"`);
if (!params) console.log('⚠️ 无 categoryParams（App 会传 null param）');
else if (params.length !== cats.length) console.log(`❌ 长度不等：categories=${cats.length} categoryParams=${params.length} → 参数错位`);
if (p0.itemType !== 'category') console.log(`❌ itemType="${p0.itemType}" ≠ 'category' → 分类项点了没反应`);

console.log('\n点分类项实测：');
const idxs = [...new Set([0, 1, Math.floor(cats.length / 2), cats.length - 1])].filter(i => i >= 0 && i < cats.length);
let ok = 0;
for (const i of idxs) {
  const label = cats[i];
  const p = params ? params[i] : undefined;
  try {
    const t0 = Date.now();
    const r = await inst.categoryComics.load(label, p, [], 1);
    const n = r?.comics?.length ?? 0;
    const first = r?.comics?.[0];
    if (n > 0) ok++;
    console.log(`  [${i}] ${String(label).padEnd(7)} param=${String(p ?? 'null').padEnd(12)} → ${String(n).padStart(3)} 本 ${String(Date.now() - t0).padStart(5)}ms  ${first ? String(first.title).slice(0, 20) : ''}`);
  } catch (e) {
    console.log(`  [${i}] ${String(label).padEnd(7)} param=${String(p ?? 'null').padEnd(12)} → ❌ ${String(e?.message || e).slice(0, 70)}`);
  }
}
console.log(ok === idxs.length ? `\n✅ 抽样 ${ok}/${idxs.length} 个分类项全部可加载` : `\n⚠️ 仅 ${ok}/${idxs.length} 可加载`);
process.exit(ok === idxs.length ? 0 : 1);
