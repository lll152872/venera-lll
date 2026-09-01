// 通用书源可用性测试工具（venera book source tester）
//
// 作用：加载任意一个 venera 书源 .js 文件，忠实模拟 App 运行时全局对象，
//       完整跑一遍「加载 -> init -> 探索页/分类/搜索/详情/章节图片」链路，
//       直接告诉你这个书源到底能不能用，不能用时给出失败环节和原因。
//
// 用法：
//   node book_source_test.mjs <书源.js 路径>            # 离线检查（不联网）
//   node book_source_test.mjs <书源.js 路径> live       # 离线 + 真实联网全链路测试
//   node book_source_test.mjs <书源.js 路径> live 关键词 # 指定搜索关键词（默认“海贼王”）
//
// 示例：
//   node book_source_test.mjs "../book source/manhuagui.js" live
//
// 依赖：cheerio（在本文件夹 npm i cheerio 即可，缺失时 live DOM 解析环节跳过）

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------- 参数解析 ----------
const [srcPathArg, mode = 'offline', keywordArg = '海贼王'] = process.argv.slice(2);
if (!srcPathArg) {
  console.error('用法: node book_source_test.mjs <书源.js 路径> [live] [搜索关键词]');
  process.exit(1);
}
const SRC_PATH = path.resolve(srcPathArg);
const LIVE = mode === 'live';

// ---------- cheerio 可选依赖 ----------
let cheerio = null;
try { cheerio = createRequire(import.meta.url)('cheerio'); }
catch { try { cheerio = (await import('cheerio')).default; } catch { /* 跳过 DOM */ } }

// ---------- 测试结果收集 ----------
const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? '  — ' + detail : ''}`);
}

// ---------- 模拟 venera 运行时全局对象 ----------
class ComicSource {
  // data / setting 存取模拟：setting 取书源声明的默认值，data 存内存
  #store = {};
  loadData(dataKey) { return this.#store[dataKey] ?? null; }
  saveData(dataKey, data) { this.#store[dataKey] = data; }
  deleteData(dataKey) { delete this.#store[dataKey]; }
  loadSetting(key) { return this.settings?.[key]?.default ?? null; }
  saveSetting(key, value) {}
  deleteSetting(key) {}
}
class Comic { constructor(o) { Object.assign(this, o); } }
class ComicDetails { constructor(o) { Object.assign(this, o); } }
class Comment { constructor(o) { Object.assign(this, o); } }

/** 用 cheerio 模拟 App 的 HtmlDocument 接口 */
function makeHtmlDocument(html) {
  if (!cheerio) throw new Error('HtmlDocument 不可用（缺 cheerio）');
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

/** 统一提取错误信息（源可能 throw 字符串或空 Error） */
function errStr(e) {
  if (e instanceof Error) return e.message || e.name || '空 Error';
  return typeof e === 'string' ? e : String(e ?? '未知错误');
}

/** 清理 headers 中的 null/undefined，避免 fetch 报错 */
function sanitizeHeaders(h) {
  const o = {};
  for (const [k, v] of Object.entries(h || {})) if (v !== null && v !== undefined) o[k] = v;
  return o;
}

const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

// ---------- Convert mock（语义对齐 assets/init.js + js_engine.dart 的 sendMessage convert 桥） ----------
//jm.js 等源的 API 签名头/数据解密全走 Convert，没有它 jm 系源完全测不了。
// ECB/CBC 均不去 padding（与 Dart 端 ECBBlockCipher.processBlock 行为一致，由调用方自行处理）。
import crypto from 'node:crypto';
const toBuf = (v) => {
  if (Buffer.isBuffer(v)) return v;
  if (v instanceof ArrayBuffer) return Buffer.from(new Uint8Array(v));
  if (ArrayBuffer.isView(v)) return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
  return Buffer.from(String(v), 'utf8');
};
const ecbCipher = (key, isEncode) => {
  const k = toBuf(key);
  const algo = `aes-${k.length * 8}-ecb`;
  return isEncode ? crypto.createCipheriv(algo, k, null) : crypto.createDecipheriv(algo, k, null);
};
const Convert = {
  encodeUtf8: (s) => Buffer.from(String(s), 'utf8'),
  decodeUtf8: (b) => toBuf(b).toString('utf8'),
  encodeGbk: (s) => { throw new Error('tester: encodeGbk 未实现（需要 iconv）'); },
  decodeGbk: (b) => { throw new Error('tester: decodeGbk 未实现（需要 iconv）'); },
  encodeBase64: (b) => toBuf(b).toString('base64'),
  decodeBase64: (s) => Buffer.from(String(s), 'base64'),
  md5: (b) => crypto.createHash('md5').update(toBuf(b)).digest(),
  sha1: (b) => crypto.createHash('sha1').update(toBuf(b)).digest(),
  sha256: (b) => crypto.createHash('sha256').update(toBuf(b)).digest(),
  sha512: (b) => crypto.createHash('sha512').update(toBuf(b)).digest(),
  decryptAesEcb: (v, k) => {
    const d = ecbCipher(k, false); d.setAutoPadding(false);
    return Buffer.concat([d.update(toBuf(v)), d.final()]);
  },
  encryptAesEcb: (v, k) => {
    const d = ecbCipher(k, true); d.setAutoPadding(false);
    return Buffer.concat([d.update(toBuf(v)), d.final()]);
  },
  decryptAesCbc: (v, k, iv) => {
    const d = crypto.createDecipheriv(`aes-${toBuf(k).length * 8}-cbc`, toBuf(k), toBuf(iv));
    d.setAutoPadding(false);
    return Buffer.concat([d.update(toBuf(v)), d.final()]);
  },
  encryptAesCbc: (v, k, iv) => {
    const d = crypto.createCipheriv(`aes-${toBuf(k).length * 8}-cbc`, toBuf(k), toBuf(iv));
    d.setAutoPadding(false);
    return Buffer.concat([d.update(toBuf(v)), d.final()]);
  },
  hexEncode: (b) => toBuf(b).toString('hex'),
  hexDecode: (s) => Buffer.from(String(s), 'hex'),
  hmac: (k, v, hash) => crypto.createHmac(hash || 'sha256', toBuf(k)).update(toBuf(v)).digest(),
  hmacString: (k, v, hash) => crypto.createHmac(hash || 'sha256', toBuf(k)).update(toBuf(v)).digest('hex'),
};
// App 运行时（assets/init.js）提供的其他全局工具，书源会直接调用
const randomInt = (min, max) => min + Math.floor(Math.random() * (max - min + 1));

// 跨 vm context 的 Map 判定：书源在 vm 里 new 出来的 Map，其构造函数与本文件的 Map 不是同一个，
// `instanceof Map` 恒为 false（同理 spread / for...of 也拿不到迭代器，因为 Symbol.iterator 跨 realm 不通用）。
// 所以统一用鸭式判断 + forEach 遍历。踩过这个坑：漫蛙吧返回 396 章节却被报成 0。
const isMap = (v) => !!v && typeof v === 'object' && typeof v.get === 'function'
  && typeof v.forEach === 'function' && typeof v.size === 'number';
const mapKeys = (m) => { const out = []; m.forEach((_v, k) => out.push(k)); return out; };
const mapValues = (m) => { const out = []; m.forEach((v) => out.push(v)); return out; };

const Network = {
  /** 模拟 Network.get，附带耗时统计 */
  async get(url, headers) {
    const t0 = Date.now();
    try {
      const res = await fetch(url, { headers: sanitizeHeaders(headers), signal: AbortSignal.timeout(15000) });
      return { status: res.status, body: await res.text(), headers: Object.fromEntries(res.headers.entries()) };
    } catch (e) {
      throw new Error(`GET ${url} 失败(${Date.now() - t0}ms): ${e.cause?.code || e.message}`);
    }
  },
  /** 模拟 Network.post */
  async post(url, headers, body) {
    const t0 = Date.now();
    try {
      const res = await fetch(url, { method: 'POST', headers: sanitizeHeaders(headers), body, signal: AbortSignal.timeout(15000) });
      return { status: res.status, body: await res.text(), headers: Object.fromEntries(res.headers.entries()) };
    } catch (e) {
      throw new Error(`POST ${url} 失败(${Date.now() - t0}ms): ${e.cause?.code || e.message}`);
    }
  },
  /** 模拟 Network.sendRequest（通用方法，漫蛙吧等源走这条，签名见 assets/init.js） */
  async sendRequest(method, url, headers, data, extra) {
    const t0 = Date.now();
    try {
      const init = { method: method || 'GET', headers: sanitizeHeaders(headers), signal: AbortSignal.timeout(15000) };
      if (data !== undefined && data !== null && method !== 'GET') init.body = data;
      const res = await fetch(url, init);
      return { status: res.status, body: await res.text(), headers: Object.fromEntries(res.headers.entries()) };
    } catch (e) {
      throw new Error(`${method} ${url} 失败(${Date.now() - t0}ms): ${e.cause?.code || e.message}`);
    }
  },
  /** 模拟 Network.fetchBytes（hitomi 用它拉二进制分片）。App 里 Dart Uint8List 过桥后是 ArrayBuffer，
      hitomi 会直接 new DataView(res.body)，所以这里必须返回 ArrayBuffer 而不是 Uint8Array */
  async fetchBytes(method, url, headers, data, extra) {
    const init = { method: method || 'GET', headers: sanitizeHeaders(headers), signal: AbortSignal.timeout(15000) };
    if (data !== undefined && data !== null && method !== 'GET') init.body = data;
    const res = await fetch(url, init);
    return { status: res.status, body: await res.arrayBuffer(), headers: Object.fromEntries(res.headers.entries()) };
  },
};

const ctx = {
  ComicSource, Comic, ComicDetails, Comment, Network, Convert, randomInt,
  HtmlDocument: cheerio ? makeHtmlDocument : null,
  console,
  log: (...a) => console.log('[log]', ...a),
  error: (...a) => console.error('[error]', ...a),
  APP: { version: '2.0.0' },
  setTimeout, fetch,
};
ctx.globalThis = ctx;
vm.createContext(ctx);

// ---------- 1. 加载书源 ----------
let src;
try { src = fs.readFileSync(SRC_PATH, 'utf8'); }
catch (e) { console.error(`无法读取书源文件: ${SRC_PATH}\n${e.message}`); process.exit(1); }

const className = (src.match(/class\s+(\w+)\s+extends\s+ComicSource/) || [])[1];
if (!className) { check('书源包含 ComicSource 子类', false, '未找到 class Xxx extends ComicSource'); finish(); process.exit(1); }

let Inst;
try {
  vm.runInContext(src + `\n;globalThis.__Inst = ${className};`, ctx, { filename: path.basename(SRC_PATH) });
  Inst = ctx.__Inst;
  check('书源可被运行时加载（无语法/引用错误）', true, `类=${className}`);
} catch (e) {
  check('书源可被运行时加载', false, e.message);
  finish(); process.exit(1);
}

const inst = new Inst();
// init 可能是 async（如 jm.js 的 refreshApiDomains），必须 await，
// 否则内部失败只会变成 unhandled rejection，然后后续所有依赖 init 副作用的调用全部莫名崩溃
try {
  await inst.init?.();
  check('init() 执行成功', true);
} catch (e) { check('init() 执行成功', false, e.message); }

// 基本信息（有的源用 baseUrl，有的源用 api，两者都不是才显示 undefined）
const siteUrl = inst.baseUrl || inst.api || inst.url;
console.log(`\n书源: ${inst.name} (key=${inst.key}, v${inst.version}, ${siteUrl})\n`);

// ---------- 2. 方法契约 ----------
const contracts = [
  ['explore 加载', typeof inst.explore?.[0]?.load === 'function'],
  ['category 加载', typeof inst.categoryComics?.load === 'function'],
  ['search 加载', typeof inst.search?.load === 'function'],
  ['comic.loadInfo', typeof inst.comic?.loadInfo === 'function'],
  ['comic.loadEp', typeof inst.comic?.loadEp === 'function'],
];
for (const [name, ok] of contracts) check(`contract: ${name}`, ok);

// ---------- LIVE ----------
let firstComic = null, firstEpId = null, exploreFirst = null, searchFirst = null, lastErr = null;
if (LIVE) {
  if (!cheerio) {
    check('LIVE 模式前置条件', false, '缺 cheerio，请在本文件夹执行 npm i cheerio');
  } else {
    console.log('\n=== LIVE: 网络连通性 ===');

    // 0. baseUrl 直连检测（区分「站点挂了」和「DNS 污染/被墙」）
    let baseUrlOk = false;
    try {
      const res = await fetch(siteUrl, { headers: { 'user-agent': DEFAULT_UA }, signal: AbortSignal.timeout(12000), redirect: 'manual' });
      baseUrlOk = res.status > 0;
      check(`站点直连 ${siteUrl}`, true, `HTTP ${res.status}`);
    } catch (e) {
      check(`站点直连 ${siteUrl}`, false, `${e.cause?.code || e.message}（疑似 DNS 污染或被墙，可在 App 设置→网络→代理 配置代理）`);
    }

    console.log('\n=== LIVE: 探索页 ===');
    if (typeof inst.explore?.[0]?.load === 'function') {
      try {
        const parts = await inst.explore[0].load(1);
        // 兼容三种返回：multiPartPage 的 [{title, comics}]、singlePage 的 {comics}、singlePageWithMultiPart 的 {标题: Comic[]}
        const partList = Array.isArray(parts)
          ? parts
          : parts?.comics
            ? [{ title: '单页', comics: parts.comics }]
            : Object.entries(parts || {}).map(([title, comics]) => ({ title, comics }));
        const count = partList.reduce((a, p) => a + (Array.isArray(p.comics) ? p.comics.length : 0), 0);
        check('explore 加载真实返回', count > 0, `${partList.length} 个板块, 共 ${count} 部漫画`);
        if (count > 0) exploreFirst = partList.find(p => p.comics?.length)?.comics[0];
      } catch (e) { check('explore 加载', false, errStr(e)); }
    }

    console.log('\n=== LIVE: 分类 ===');
    if (typeof inst.categoryComics?.load === 'function') {
      try {
        const cat = inst.category?.parts?.[0];
        const param = cat?.categoryParams?.[1] ?? '';
        // 从 optionList 构造默认选项（取各组的 default 或第一项的值），避免空 options 导致源内报错
        const options = (inst.categoryComics.optionList || []).map(g => {
          const opts = g.options || [];
          const def = opts.find(o => o.startsWith('-')) || opts[0] || '';
          return def.split('-')[0];
        });
        const r = await inst.categoryComics.load(cat?.categories?.[1] ?? '', param, options, 1);
        check('category 加载真实返回', r.comics?.length > 0, `${r.comics?.length} 部, maxPage=${r.maxPage}`);
        if (r.comics?.length && !firstComic) firstComic = r.comics[0];
      } catch (e) { check('category 加载', false, errStr(e)); }
    }

    console.log('\n=== LIVE: 搜索 ===');
    if (typeof inst.search?.load === 'function') {
      try {
        const r = await inst.search.load(keywordArg, [], 1);
        check(`搜索「${keywordArg}」真实返回`, r.comics?.length > 0, `${r.comics?.length} 条, maxPage=${r.maxPage}`);
        if (r.comics?.length) { firstComic = firstComic || r.comics[0]; searchFirst = r.comics[0]; }
      } catch (e) { check(`搜索「${keywordArg}」`, false, errStr(e)); }
    }

    console.log('\n=== LIVE: 详情 + 章节 ===');
    if (typeof inst.comic?.loadInfo === 'function') {
      // 多候选依次尝试（去重），直到某部漫画成功解析出章节
      const candidates = [firstComic, searchFirst, exploreFirst].filter(c => c?.id != null);
      const seen = new Set();
      let info = null, chosen = null;
      for (const c of candidates) {
        if (seen.has(c.id)) continue;
        seen.add(c.id);
        try {
          const cand = await inst.comic.loadInfo(c.id);
          const hasCh = isMap(cand.chapters) ? cand.chapters.size > 0
            : (cand.chapters && Object.keys(cand.chapters).length > 0);
          if (!info) info = cand;
          if (hasCh) { info = cand; chosen = c; break; }
        } catch (e) { if (!info) lastErr = e; }
      }
      if (!info) {
        check('comic.loadInfo', false, errStr(lastErr) || '所有候选漫画加载失败');
      } else {
        const ch = info.chapters;
        let groupCount = 0, chCount = 0;
        let isGroupMap = false;
        if (isMap(ch)) {
          const vals = mapValues(ch);
          isGroupMap = vals.some(v => isMap(v) || (typeof v === 'object' && v !== null));
          if (isGroupMap) {
            groupCount = ch.size;
            chCount = vals.reduce((a, m) => a + (isMap(m) ? m.size : Object.keys(m || {}).length), 0);
          } else { chCount = ch.size; }
        } else if (ch && typeof ch === 'object') { chCount = Object.keys(ch).length; }
        check('comic.loadInfo 真实返回', !!info.title, `标题=${info.title}, 章节组=${groupCount}, 章节=${chCount}${chosen ? '' : '（候选均无章节，取首个结果继续）'}`);
        // 取第一个章节 id
        if (isGroupMap) {
          for (const m of mapValues(ch)) { firstEpId = isMap(m) ? mapKeys(m)[0] : Object.keys(m || {})[0]; if (firstEpId) break; }
        } else if (isMap(ch)) { firstEpId = mapKeys(ch)[0]; }
        else if (ch && typeof ch === 'object') { firstEpId = Object.keys(ch)[0]; }
        if (!firstEpId) check('章节 id 提取', false, '未能从 chapters 结构中提取到任何章节 id（结构未覆盖）');
      }
    } else if (!firstComic) {
      check('comic.loadInfo', false, '前置失败：没有拿到任何漫画 id（上面某环节已失败）');
    }

    if (firstComic && firstEpId && typeof inst.comic?.loadEp === 'function') {
      console.log('\n=== LIVE: 章节图片 ===');
      try {
        const ep = await inst.comic.loadEp(firstComic.id, firstEpId);
        check('comic.loadEp 返回图片列表', ep.images?.length > 0, `${ep.images?.length} 张`);
        if (ep.images?.length) {
          // 抽查第一张图片是否可下载（带 onImageLoad 头）
          const cfg = typeof inst.comic.onImageLoad === 'function' ? (inst.comic.onImageLoad(ep.images[0], firstComic.id, firstEpId) || {}) : {};
          try {
            const res = await fetch(ep.images[0], { headers: sanitizeHeaders(cfg.headers), signal: AbortSignal.timeout(15000) });
            check('章节图片可下载', res.ok, `HTTP ${res.status} ${ep.images[0].slice(0, 70)}`);
          } catch (e) {
            check('章节图片可下载', false, `${errStr(e)} ${ep.images[0].slice(0, 70)}`);
          }
        }
      } catch (e) { check('comic.loadEp', false, errStr(e)); }
    }
  }
}

finish();

function finish() {
  const pass = results.filter(r => r.ok).length;
  console.log(`\n=== 合计 ${pass}/${results.length} 通过 ${pass === results.length && results.length > 0 ? '🎉 书源可用' : ''} ===`);
  const failed = results.filter(r => !r.ok);
  if (failed.length) {
    console.log('失败项：');
    failed.forEach(f => console.log(`  - ${f.name}${f.detail ? ' :: ' + f.detail : ''}`));
    process.exitCode = 1;
  }
}
