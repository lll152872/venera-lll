// JM 书源测速按钮冒烟测试（针对 optimizeNodes / testImageSpeed）
// 复用 book_source_test.mjs 的 Convert 真实实现 + 可控 Network mock。
// 目的：确认两个新方法在 venera 运行时语义下不抛引用错误、排序/格式化/字节统计路径正确。

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_PATH = path.resolve(__dirname, '../../book source/jm.js');

// ---------- Convert（与测试器一致，全量真实现） ----------
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
  decryptAesCbc: (v, k, iv) => crypto.createDecipheriv(`aes-${toBuf(k).length * 8}-cbc`, toBuf(k), toBuf(iv)),
  encryptAesCbc: (v, k, iv) => crypto.createCipheriv(`aes-${toBuf(k).length * 8}-cbc`, toBuf(k), toBuf(iv)),
  hexEncode: (b) => toBuf(b).toString('hex'),
  hexDecode: (s) => Buffer.from(String(s), 'hex'),
  hmac: (k, v, hash) => crypto.createHmac(hash || 'sha256', toBuf(k)).update(toBuf(v)).digest(),
  hmacString: (k, v, hash) => crypto.createHmac(hash || 'sha256', toBuf(k)).update(toBuf(v)).digest('hex'),
};

class ComicSource {
  #store = {};
  loadData(k) { return this.#store[k] ?? null; }
  saveData(k, v) { this.#store[k] = v; }
  deleteData(k) { delete this.#store[k]; }
  loadSetting(key) { return this.settings?.[key]?.default ?? null; }
  saveSetting() {}
  deleteSetting() {}
}
class Comic { constructor(o) { Object.assign(this, o); } }
class ComicDetails { constructor(o) { Object.assign(this, o); } }
class Comment { constructor(o) { Object.assign(this, o); } }

// ---------- 可控 Network mock ----------
let GET_RESPONDER = null;   // (url, headers) => { status, body } | throws
let FETCHBYTES_RESPONDER = null;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const Network = {
  async get(url, headers) {
    if (!GET_RESPONDER) throw new Error('GET_RESPONDER 未设置');
    const r = await GET_RESPONDER(url, headers);
    return { status: r.status, body: r.body, headers: {} };
  },
  async post(url, headers, body) {
    if (!GET_RESPONDER) throw new Error('GET_RESPONDER 未设置');
    const r = await GET_RESPONDER(url, headers);
    return { status: r.status, body: r.body, headers: {} };
  },
  async sendRequest(method, url, headers) { return this.get(url, headers); },
  async fetchBytes(method, url, headers) {
    if (!FETCHBYTES_RESPONDER) throw new Error('FETCHBYTES_RESPONDER 未设置');
    const r = await FETCHBYTES_RESPONDER(url, headers);
    return { status: r.status, body: r.body, headers: {} };
  },
};

// ---------- UI 捕获 ----------
let lastDialog = null;
const UI = {
  showMessage: (m) => { /* 忽略进度提示 */ },
  showDialog: (title, message, buttons) => { lastDialog = { title, message, buttons }; },
};

const ctx = {
  ComicSource, Comic, ComicDetails, Comment, Network, Convert, UI,
  console, log: (...a) => console.log('[log]', ...a), error: (...a) => console.error('[error]', ...a),
  APP: { version: '2.0.0' }, setTimeout, fetch,
};
ctx.globalThis = ctx;
vm.createContext(ctx);

// ---------- 加载书源 ----------
const src = fs.readFileSync(SRC_PATH, 'utf8');
const className = (src.match(/class\s+(\w+)\s+extends\s+ComicSource/) || [])[1];
if (!className) { console.error('未找到 ComicSource 子类'); process.exit(1); }
vm.runInContext(src + `\n;globalThis.__Inst = ${className};`, ctx, { filename: 'jm.js' });
const Inst = ctx.__Inst;
const inst = new Inst();

let pass = 0, fail = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? '  — ' + detail : ''}`);
  ok ? pass++ : fail++;
};

// ---------- 测试 1: optimizeNodes 延迟排序 ----------
(async () => {
  // 固定 4 条线路，模拟不同延迟 + 一条失败
  Inst.apiDomains = ['a.test', 'b.test', 'c.test', 'd.test'];
  GET_RESPONDER = async (url) => {
    if (url.includes('a.test')) { await sleep(300); return { status: 200, body: '{}' }; }
    if (url.includes('b.test')) { await sleep(100); return { status: 200, body: '{}' }; }
    if (url.includes('c.test')) { await sleep(500); return { status: 200, body: '{}' }; }
    if (url.includes('d.test')) { throw new Error('conn refused'); } // 模拟失败
    return { status: 200, body: '{}' };
  };
  lastDialog = null;
  await inst.optimizeNodes();
  const ok1 = lastDialog && lastDialog.title === '节点延迟';
  // 最快应是 b.test（100ms），且失败项 d.test 排最后
  const msg = lastDialog?.message || '';
  const bFirst = msg.indexOf('b.test') < msg.indexOf('a.test') && msg.indexOf('a.test') < msg.indexOf('c.test');
  const dLast = msg.lastIndexOf('d.test') > msg.lastIndexOf('c.test');
  check('optimizeNodes: 弹窗生成且 b.test 最快、d.test 失败置底', ok1 && bFirst && dLast,
    ok1 ? `顺序片段: ${msg.split('\n').slice(0,6).join(' / ')}` : '无对话框');

  // ---------- 测试 2: testImageSpeed 下载字节统计 + 排序 ----------
  // 覆盖 inst.get 走 /setting（绕开加密，专注测速逻辑），按 shunt 返回不同 img_host
  const hosts = ['https://h1.test', 'https://h2.test', null, 'https://h4.test', 'https://h5.test'];
  inst.get = async (url) => {
    const m = url.match(/app_img_shunt=(\d+)/);
    const idx = m ? parseInt(m[1]) - 1 : 0;
    const h = hosts[idx];
    return JSON.stringify(h ? { img_host: h } : {});
  };
  // 下载字节：h1=200KB(快) h2=1MB(更快) h4=50KB(慢) h5=400KB；h3 无 host 跳过
  const sizeMap = { 'h1.test': 200*1024, 'h2.test': 1024*1024, 'h4.test': 50*1024, 'h5.test': 400*1024 };
  FETCHBYTES_RESPONDER = async (url) => {
    const key = Object.keys(sizeMap).find(k => url.includes(k));
    const n = key ? sizeMap[key] : 1024;
    const buf = new Uint8Array(n);
    await sleep(Math.max(20, Math.round(n / 40000))); // 越大睡越久，模拟真实吞吐差异
    return { status: 200, body: buf.buffer }; // ArrayBuffer（与 App 过桥一致）
  };
  lastDialog = null;
  await inst.testImageSpeed();
  const ok2 = lastDialog && lastDialog.title === '图片分流测速';
  const msg2 = lastDialog?.message || '';
  // 速度降序应为：h2(1MB) > h5(400KB) > h1(200KB) > h4(50KB)；无 host 的 h3 显示“获取失败”
  const p = (k) => msg2.indexOf(k);
  const h2First = p('h2.test') < p('h5.test') && p('h5.test') < p('h1.test') && p('h1.test') < p('h4.test');
  const h3Fail = msg2.includes('获取失败') && msg2.includes('连接失败');
  check('testImageSpeed: 弹窗生成、h2>h5>h1>h4 降序、无host项获取失败', ok2 && h2First && h3Fail,
    ok2 ? `速度行: ${msg2.split('\n').filter(l=>l.includes('速度')).join(' / ')}` : '无对话框');

  // ---------- 测试 3: fetchBytes 返回 ArrayBuffer 时 byteLength 链路 ----------
  // 注意：跨 vm realm 下 `instanceof Uint8Array` 不可靠（与 Map 同坑），用 byteLength 鸭子判定
  FETCHBYTES_RESPONDER = async () => ({ status: 206, body: new Uint8Array(12345).buffer });
  const dl = await inst._downloadImage('https://x.test/p.webp', 5000);
  check('_downloadImage: ArrayBuffer body -> byteLength=12345', dl && typeof dl.byteLength === 'number' && dl.byteLength === 12345,
    `type=${dl?.constructor?.name} len=${dl?.byteLength}`);

  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('❌ 冒烟测试异常:', e); process.exit(1); });
