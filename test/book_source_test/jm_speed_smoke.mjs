// JM 书源测速按钮冒烟测试（针对 optimizeNodes / testImageSpeed / _applySetting）
// 复用 book_source_test.mjs 的 Convert 真实实现 + 可控 Network/UI mock。
// 目的：
//   1) 确认测速链路在 venera 运行时语义下不抛引用错误、排序/格式化/字节统计正确；
//   2) 确认测完弹出选择框、选中后能把结果写回书源设置存储（data['settings']），
//      并即时生效（baseUrl / imageUrl），且整对象读-改-写不弄丢其它设置项。
//
// 关于写设置：venera 未开放 saveSetting（Dart 只有 load_setting，save_data 拦单数 'setting'），
// 书源设置实际存于 data['settings']，所以这里按 Dart 侧 load_setting 的语义 mock：
//   data['settings'][key] ?? settings[key].default

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

// data 走公开属性，便于断言写回结果；loadSetting 严格对齐 Dart 侧读取优先级
class ComicSource {
  data = {};
  loadData(k) { return this.data[k] ?? null; }
  saveData(k, v) { this.data[k] = v; }
  deleteData(k) { delete this.data[k]; }
  loadSetting(key) {
    const s = this.data['settings'];
    if (s && s[key] !== undefined) return s[key];
    return this.settings?.[key]?.default ?? null;
  }
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

// ---------- UI mock：捕获弹窗 + 可编排选择结果 ----------
let SELECT_SEQ = [];      // 每次 showSelectDialog 依次返回的索引（空则返回 null 视为取消）
let selectCalls = [];     // 记录所有选择框调用
let lastMessages = [];    // 记录 showMessage
const UI = {
  showMessage: (m) => { lastMessages.push(String(m)); },
  showDialog: () => {},
  showSelectDialog: (title, options, initialIndex) => {
    selectCalls.push({ title, options, initialIndex });
    const v = SELECT_SEQ.length ? SELECT_SEQ.shift() : null;
    return Promise.resolve(v);
  },
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

(async () => {
  // ================= 测试 1: optimizeNodes 延迟排序 + 选择写回 apiDomain =================
  Inst.apiDomains = ['a.test', 'b.test', 'c.test', 'd.test'];
  GET_RESPONDER = async (url) => {
    if (url.includes('a.test')) { await sleep(300); return { status: 200, body: '{}' }; }
    if (url.includes('b.test')) { await sleep(100); return { status: 200, body: '{}' }; }
    if (url.includes('c.test')) { await sleep(500); return { status: 200, body: '{}' }; }
    if (url.includes('d.test')) { throw new Error('conn refused'); }
    return { status: 200, body: '{}' };
  };
  selectCalls = []; lastMessages = []; SELECT_SEQ = [0]; // 选排序后第 0 项（最快 = 线路2 b.test）
  await inst.optimizeNodes();

  const c1 = selectCalls[0];
  const ok1call = c1 && c1.title.includes('节点');
  // 排序：b(100) < a(300) < c(500) < d(失败置底)
  const opt = c1?.options || [];
  const orderOk = opt[0]?.includes('b.test') && opt[1]?.includes('a.test')
    && opt[2]?.includes('c.test') && opt[3]?.includes('d.test');
  const failLast = opt[3]?.includes('连接失败');
  // 当前设置 apiDomain 默认 '1' -> 对应 a.test，应在排序后第 1 位
  const initOk = c1?.initialIndex === 1;
  const wroteApi = inst.data['settings']?.apiDomain === '2';
  const saidOk = lastMessages.some(m => m.includes('已切换到'));
  check('optimizeNodes: 弹选择框、延迟升序(b最快/d失败置底)、初始高亮当前线路、选中写回 apiDomain',
    ok1call && orderOk && failLast && initOk && wroteApi && saidOk,
    `title=${c1?.title} init=${c1?.initialIndex} apiDomain=${inst.data['settings']?.apiDomain}`);

  // ================= 测试 2: testImageSpeed 测速 + 选择写回 imageStream 并即时换图床 =================
  const hosts = ['https://h1.test', 'https://h2.test', null, 'https://h4.test', 'https://h5.test'];
  inst.get = async (url) => {
    const m = url.match(/app_img_shunt=(\d+)/);
    const idx = m ? parseInt(m[1]) - 1 : 0;
    const h = hosts[idx];
    return JSON.stringify(h ? { img_host: h } : {});
  };
  const sizeMap = { 'h1.test': 200 * 1024, 'h2.test': 1024 * 1024, 'h4.test': 50 * 1024, 'h5.test': 400 * 1024 };
  FETCHBYTES_RESPONDER = async (url) => {
    const key = Object.keys(sizeMap).find(k => url.includes(k));
    const n = key ? sizeMap[key] : 1024;
    const buf = new Uint8Array(n);
    await sleep(Math.max(20, Math.round(n / 40000)));
    return { status: 200, body: buf.buffer };
  };
  selectCalls = []; lastMessages = []; SELECT_SEQ = [0]; // 选最快 = h2.test（选项2）
  const beforeImg = inst.imageUrl;
  await inst.testImageSpeed();

  const c2 = selectCalls[0];
  const ok2call = c2 && c2.title.includes('分流');
  const o2 = c2?.options || [];
  const p = (k) => o2.findIndex(s => s.includes(k));
  // 速度降序 h2(1MB) > h5(400KB) > h1(200KB) > h4(50KB)；h3 无 host
  const order2 = p('h2.test') === 0 && p('h5.test') === 1 && p('h1.test') === 2 && p('h4.test') === 3;
  const wroteImg = inst.data['settings']?.imageStream === '2';
  const imgSwitched = inst.imageUrl.includes('h2.test') && beforeImg !== inst.imageUrl;
  check('testImageSpeed: 弹选择框、速度降序(h2>h5>h1>h4)、选中写回 imageStream 且立即换图床',
    ok2call && order2 && wroteImg && imgSwitched,
    `imageStream=${inst.data['settings']?.imageStream} imageUrl=${inst.imageUrl}`);

  // ================= 测试 3: _applySetting 整对象读-改-写不丢其它设置项 =================
  // 预置用户已改过的其它设置，再写一个新键，确认全部保留
  inst.data['settings'] = Object.assign({}, inst.data['settings'], {
    favoriteOrder: 'mp',
    refreshDomainsOnStart: false,
  });
  inst._applySetting('apiDomain', '3');
  const s3 = inst.data['settings'] || {};
  const keepOk = s3.favoriteOrder === 'mp' && s3.refreshDomainsOnStart === false && s3.imageStream === '2';
  const writeOk = s3.apiDomain === '3';
  check('_applySetting: 写入目标键且保留 favoriteOrder/refreshDomainsOnStart/imageStream',
    keepOk && writeOk,
    `settings=${JSON.stringify(s3)}`);

  // ================= 测试 4: 取消选择不修改设置 =================
  selectCalls = []; lastMessages = []; SELECT_SEQ = [null]; // 模拟取消
  const beforeCancel = inst.data['settings']?.apiDomain;
  await inst.optimizeNodes();
  const noChange = inst.data['settings']?.apiDomain === beforeCancel;
  check('取消选择：设置保持不变', noChange,
    `apiDomain=${inst.data['settings']?.apiDomain} (取消前 ${beforeCancel})`);

  // ================= 测试 5: fetchBytes ArrayBuffer -> byteLength（跨 realm 用鸭子判定） =================
  FETCHBYTES_RESPONDER = async () => ({ status: 206, body: new Uint8Array(12345).buffer });
  const dl = await inst._downloadImage('https://x.test/p.webp', 5000);
  check('_downloadImage: ArrayBuffer body -> byteLength=12345',
    dl && typeof dl.byteLength === 'number' && dl.byteLength === 12345,
    `type=${dl?.constructor?.name} len=${dl?.byteLength}`);

  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('❌ 冒烟测试异常:', e); process.exit(1); });
