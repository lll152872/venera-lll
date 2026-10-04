# 书源（Comic Source）开发注意事项

> **适用场景**：只开发 / 修改书源 JS。本篇与构建、版本号、CI 完全无关——只改书源时不需要读构建文档。
> 书源 `.js` 文件**不要 push 进主仓库**（属本地私有内容，不应进入公共仓库），见 `GIT_WORKFLOW.md` 第 2.1 节。
> 导航入口见 `../0_必看.md`。

## 1. `flutter_js` 引擎类型转换陷阱（最容易踩的坑）

| JS 类型 | 传给 Dart 后变成 | 能否用于 `Uint8List` 参数 |
|---|---|---|
| `[]`（普通数组） | `List<dynamic>` | ❌ 报 `List<dynamic> is not Uint8List` |
| `new Uint8Array(...)` | `Map<String, dynamic>` | ❌ 报 `Map is not Uint8List` |
| `new Uint8Array(...).buffer` | `Uint8List` ✅ | ✅ 正确 |

**结论**：传字节给 Dart 端（如 `sendMessage` 的 `value`/`key`/`iv`）必须用 `.buffer`（`ArrayBuffer`），不能直接传 `Uint8Array` 或普通数组。

## 2. 全局对象名

- 加密/解码对象叫 **`Convert`**，不是 `Venera`
- `Convert.decryptAesCbc(value, key, iv)` — AES-CBC 解密
- `Convert.decodeBase64(value)` — Base64 解码
- `Convert.md5(value)` — MD5 哈希
- `sendMessage({method: "convert", type: "aes-cbc", value, key, iv, isEncode: false})` — 直接调 convert

## 3. JS API 限制（不可用的标准 API）

| 不可用 | 替代方案 |
|---|---|
| `TextEncoder` | `str.charCodeAt(i)` 逐字节 |
| `Array.from()` | `for` 循环 + `push` |
| `Symbol.iterator` | 不支持 → 不用 `for...of` |

## 4. `onImageLoad` / `onResponse` 图片后处理

```js
comic = {
  onImageLoad: (imageKey, comicId, ep) => {
    // 返回配置，onResponse 回调在图片下载后被调用
    return {
      onResponse: (buffer) => {
        // buffer 是下载的原始字节 → 解密 → 返回 ArrayBuffer
        let view = new Uint8Array(buffer);
        // ... AES 解密 ...
        return new Uint8Array(decrypted).buffer;
      },
    };
  },
};
```

- `onResponse` 接收的是 `ArrayBuffer`，返回也必须是 `ArrayBuffer`（或能转成 `List<int>` 的类型）
- Dart 端检查 `result is List<int>` → `.buffer`（`ArrayBuffer`）能通过
- `onResponse` 在缓存命中和网络下载两条路径**都会执行**

## 5. 书源结构骨架

```js
class MySource extends ComicSource {
  name = '源名称';
  key = 'unique_key';
  version = '1.0.0';
  minAppVersion = '1.4.0';
  url = 'https://cdn.jsdelivr.net/gh/.../my_source.js';  // Venera 更新用

  // 搜索
  search = { load: async (keyword, options, page) => { return { comics: [...], maxPage: N }; } };

  // 漫画详情
  comic = {
    loadInfo: async (id) => { return new ComicDetails({...}); },
    loadEp: async (comicId, epId) => { return { images: ['url1', 'url2'] }; },
  };
}
```

## 6. `loadEp` 注意事项

- 返回格式：`{ images: ['url1', 'url2', ...] }`
- API 参数名注意**下划线 vs 驼峰**：漫蛙吧的图片 API 用 `image_source`（下划线），请求参数用 `page_size`
- 分页拉全：如果 API 有分页上限（如每页 50 张），需循环 `page++` 直到返回数 < pageSize

## 7. 网络请求

```js
let res = await Network.get(url);
// res = { status: 200, body: '...' }

let res = await Network.post(url, headers, body);
```

- Cookie：`Network.setCookies(domain, [new Cookie({name, value, domain})])`
- 删除：`Network.deleteCookies(domain)`

## 8. HTML 解析

```js
let doc = new HtmlDocument(html);
let el = doc.querySelector('div.title');
let list = doc.querySelectorAll('a.item');
let text = el.text.trim();
let href = el.attributes['href'];
```

## 9. 书源 url 字段规则

- `url` 必须可公开访问（jsdelivr CDN），Venera 用此地址**检查更新**
- 格式：`https://cdn.jsdelivr.net/gh/用户名/仓库名@分支/路径/xxx.js`
- 不改动的官方源直接用官方 CDN，不需要指向自己的仓库
- 自己修改过的源才指向自己仓库（如 manwaba.js → `lll152872/venera-lll`）

## 10. 图片解密常见模式（manwaba 案例）

```js
// AES-256-CBC 解密
let keyBytes = new Uint8Array(32);
for (let i = 0; i < 32; i++) keyBytes[i] = rawKey.charCodeAt(i);
let iv = view.slice(0, 16);      // 前 16 字节 = IV
let ciphertext = view.slice(16); // 其余 = 密文
let decrypted = sendMessage({
  method: 'convert',
  type: 'aes-cbc',
  value: ciphertext.buffer,  // ← 必须是 .buffer
  key: keyBytes.buffer,       // ← 同上
  iv: iv.buffer,              // ← 同上
  isEncode: false,
});
return new Uint8Array(decrypted).buffer;
```

- 解密密钥通常从网站 `base.js` 提取（搜 `getSecureImageUrl` / `AES` / `decrypt`）
- 注意：`isEncode: false` 表示**解密**（不是加密）
- **封面也要解密（2026-08 manwaba 实测）**：站点把 `en_images` 路径下所有图（含 `cover/` 封面）都 AES 加密后，若书源只写了 `onImageLoad` 没写 `onThumbnailLoad`，封面会显示为密文乱码/黑图。因为 Venera 封面走 `CachedImage → ImageDownloader.loadThumbnail → getThumbnailLoadingConfig`（对应 JS `onThumbnailLoad`），与阅读页 `onImageLoad` 是**两条独立通道**。修法：解密逻辑抽成公共方法（如 `_imageLoadConfig`），`onImageLoad` 与 `onThumbnailLoad` 共用。
- **API 域名 301 跳转（务必写死最终域名）**（2026-08 / 2026-09 两次实测）：
  - `mwuu.cc` → `manwapi.cc` → `manwali.cc` → **`manwari.cc`**（2026-09-01 实测的终点）。
  - Venera 的 `RHttpAdapter` 有 `RedirectSettings.limited(5)` 会自动跟随，**功能不受影响但延迟翻倍**。
  - 量化（2026-09-01，3 次中位数，端到端口径）：`manwali.cc` **1995ms**（建连成本就有 979ms，全是两跳握手）vs `manwari.cc` 直连 **963ms**。
  - 为什么会被放大：漫蛙吧 `loadInfo`/`loadEp` 是**串行**多次请求（章节按 100 条分页 + 图片按 50 张分页循环），每请求都重复付一次「DNS+TCP+TLS」往返成本。一本 300 话漫画 ≈ 3 次章节请求 + N 次图片请求，累积可达数秒。
  - 修法：把 `api` 改成 `https://manwari.cc/api`，并加注释标记「不要留会 301 的中间域名」。

### 漫蛙吧 API 性能优化实录（v1.4.0，2026-09-01）

先探测、再动手。三个实测事实（`book source/probe_api.py`）：

1. **`comic/{id}` 返回的 `data.id` === 传入的 id** → 详情请求和章节列表请求之间没有真实依赖，可以 `Promise.all` 并发（QuickJS 引擎支持 Promise.all，copy_manga / hitomi 早已在用）。
2. **章节 API `pageSize=500` 一次返回全部**（228 话实测无截断），且响应自带 `pagination.total` → 「pageSize=1 先探测总数」那一次请求可以整个删掉。
3. **图片 API 单页硬上限 100**：`page_size=500` 也只回 100 条（total=153 时只给 100）→ 服务端截断。**千万不要把 page_size 改大于 100 还以为拉全了，会丢图**。用 100，靠 total 判断是否翻页。

优化后的请求模式（v1.4.0）：

- `loadInfo`：详情 ∥ 章节首页（并发）→ 若 `返回条数 < total` 才并发补页。228 话漫画从 5 次串行请求 → 2 次并发。
- `loadEp`：首页 `page_size=100` → 剩余页并发。153 张图从 5 次串行 → 3 次（1+2）。

实测对比（node 直连，海贼王 6566 号 / 396 话 / 209 图章节）：

| 环节 | 旧耗时 | 新耗时 | 旧请求 | 新请求 |
|---|---|---|---|---|
| loadInfo | 1706ms | 787ms | 6 | 2 |
| loadEp | 1655ms | 587ms | 3 | 3 |
| **合计** | **3361ms** | **1374ms** | **12** | **5** |

**提速 2.45x，请求数 -58%**。新旧结果一致（396 章节 / 209 图片，图片数相等证明截断处理正确）。

附带修复：

- **修复⑧**：`categoryComics` 的 POST 一直没带 `Content-Type: application/json`，站点（.NET 后端）返回 415 Unsupported Media Type → **分类页在 App 里整页报错**。一直没人发现是因为书源测试工具此前没测这一环。

图床结论：`image_source` 参数会被原样拼进返回的图片 URL（传什么域名返回什么域名，图床可切换），但扫遍 `img1/img2/tu1/tu2/cdn/pic.mhttu.cc` 全部 DNS 不存在，**`tu.mhttu.cc` 是唯一可用图床**（单图端到端 ~1376ms，TLS 握手占一半）。图床层无优化空间；若要再快，方向在 App 层：连接复用（`IOHttpClientAdapter` 的 `createHttpClient` 只建一次即可）与阅读页并发预加载。

## 11. 虫虫漫画 (warchina / warchina.com) 源要点

纯 HTML 站，无干净 JSON API。关键解析点（均实测）：

- **搜索**：`https://warchina.com/search?keyword={kw}`，单页无分页（`maxPage:1`），最多约 85 条。
- **详情**：`https://warchina.com/comic/{id}/`。**元数据优先用 `<meta og:novel:*>`**（静态、最可靠）：`og:title`/`og:image`(=封面 _small.jpg)/`og:novel:author`/`og:novel:status`/`og:novel:update_time`。
  - **坑**：`最后更新：` 后日期被包在 `<font color="red">` 里，散文正则 `最后更新:\s*(\d...)` 会失配，必须改用 meta。
  - **分类**：从 `info3` 信息块"漫画类别："后取 `<a>` 文本，**不要**用 `querySelector('a[href*="/cate/"]')` 取第一个——右侧"精彩推荐"区的 cate 链接会干扰（实测首个是推荐区的 JJ韩漫而非本作分类）。
  - 站点**无独立"标签/题材"区**（grep 标签/关键词/类型/tag/label 全无命中），只有大类（国漫/韩漫），tags 里能放的只有 作者/分类/状态。
- **章节列表**：详情页所有 `<a href="/comic/{id}/{cid}.html">`，按 cid 去重收集成数组，再 **`reverse()` 反转为正序（第1话在前）**。站点 HTML 默认倒序（最新/番外在前、第1话在尾），若不反转，第1话会变成最后一章（v1.0.0 的 bug，v1.0.1 修复）。注意同一话常有多个上传 cid（旧版重传），全部保留即可。
- **章节图片（核心）**：阅读页内嵌 `var params = {...,"chapter_images2":"BASE64",...}`。
  - `chapter_images2` = Base64 编码的图片 URL 串，分隔符 `$qingtiandy$`。
  - 流程：`Convert.decodeBase64(b64)` → 字节 → `Convert.decodeUtf8(bytes)` → 字符串 → `.split('$qingtiandy$')` = 完整图片 URL 数组。
  - 字段名偶尔为 `chapter_images`（兜底正则）。图片是标准 WebP，**无需解密**。
- **图片 CDN 反 referer（坑）**：图片在 `*.g-mh.online`，**带 warchina referer 的请求被拒**（503/超时），无 referer 直连成功。故 `onImageLoad` 只给 UA、**故意不设 referer**。若 App 实测仍 503，是 venera 网络层自动注入了 referer，改 `referer:''` 或换成图片自身 origin 做 referer。
- **封面**：`_small.jpg` 是真封面（17KB），去掉 `_small` 反而 404，保留 `_small`。
- **⚠️ 站点 TLS 证书已过期**（2026-09-01 实测）：`curl` 报 `SEC_E_CERT_EXPIRED (0x80090328) - 收到的证书已过期`。curl/浏览器提示"不安全"但仍可继续；Dart `HttpClient` **默认校验证书**，App 内大概率直接抛 `CERTIFICATE_VERIFY_FAILED` 导致整源不可用。若用户反馈虫虫漫画加载失败，先复测证书是否已续期——续期前不要浪费时间改解析逻辑。

## 12. 精确标签搜索接口 `search.tagSearch`（2026-08 新增）

App 搜索层（`SearchQuery`）支持 `tag:xxx` / `author:xxx` / `-xxx` / `"短语"` 语法。其中 `tag:` 语法的行为分两条通道：

- **书源实现了 `search.tagSearch`** → 下推给书源走原生标签精确搜索（如 JM 的 `main_tag=3`）
- **未实现** → 自动退回「全文搜索 + App 客户端 tag 过滤」（原有行为，无需改动）

JS 侧可选实现（签名与 `search.load` 类似，多一个 keyword 参数）：

```js
search = {
  load: async (keyword, options, page) => { ... },

  /**
   * [Optional] 精确标签搜索接口（配合 App 搜索层 `tag:` 语法）
   * @param tag {string} - 标签名（来自 `tag:` 语法或详情页 tag 点击）
   * @param keyword {string} - 剩余普通关键词（已剥离全部语法，可为空串）
   * @param options {string[]} - options from optionList
   * @param page {number}
   */
  tagSearch: async (tag, keyword, options, page) => {
    // 例：JM main_tag=3；keyword 非空时以「+关键词」追加（JM 语法：必须包含）
    let rest = keyword.trim()
    let query = rest.length > 0 ? `${tag} +${rest}` : tag
    query = encodeURIComponent(query).replace(/%20/g, '+')
    let url = `${this.baseUrl}/search?search_query=${query}&main_tag=3&o=mr`
    if (page > 1) url += `&page=${page}`
    let res = await this.get(url)
    let data = JSON.parse(res)
    return { comics: data.content.map(e => this.parseComic(e)), maxPage: Math.ceil(data.total / 80) }
  },
}
```

要点：

- 返回格式与 `search.load` 相同：`{ comics: [...], maxPage: N }`
- 下推时 App 端 `filterResult` 仍会兜底：多个 `tag:` 过滤器只把**首个**下推书源，其余（及 `author:`、排除词）继续客户端过滤，AND 语义不变
- `onClickTag` 返回 `keyword: 'tag:' + tag` 即可让详情页 tag 点击复用同一条链路（jm.js 已接）
- Dart 端对应：`parser.dart` 检测 `search.tagSearch` 构建 `TagSearchFunction`，`SearchPageData.tagSearch` 字段；`SearchQuery.plainKeyword` 专供下推（不带语法字面量，不回退）

## 13. 漫画柜 (manhuagui / manhuagui.com) 源要点（2026-08-28 引入）

**直接采用官方源** `venera-app/venera-configs` 的 manhuagui.js v1.2.1（逐字节一致，未改动），作为包子漫画的替代/补充。站点质量高于 baozi（官方在维护、章节全）。

- **接入方式**：官方 CDN（jsdelivr）原样下载 → 放入 `book source/manhuagui.js` → index.json 增加第 7 条（key `ManHuaGui`，version 1.2.1）。
- **版本约束**：js 内声明 `minAppVersion: 1.4.0`，App 2.0.0 满足。
- **技术特征**：详情/章节走 `__VIEWSTATE`（LZString 解压后 JSON 解析），图片 CDN 在 `us.hamreus.com`（需要正确 referer，官方源已处理）。若站点结构变更，优先对照官方仓库更新版本，不要本地魔改。
- **网络注意**：manhuagui.com 直连在部分网络环境超时（被墙/CDN 抖动），App 侧若加载失败先确认站点可达性。
- **升级跟踪**：官方源更新时同步 `book source/manhuagui.js` + index.json 两处 version 字段。

## 14. 书源连通性 / 延迟基准测试

脚本：`book source/bench_sources.py`（纯 Python 标准库，无第三方依赖）。

```bash
cd "book source"
python bench_sources.py          # 结果打印到终端 + 写 bench_result.json
```

- 原理：裸 `socket` + `ssl` 手工发 HTTP/1.1，分段计时 **DNS / TCP / TLS / TTFB / TOTAL**，自动跟随 3xx 并**累加**各跳耗时（这是 curl 的 `time_starttransfer` 做不到的——它只报最后一跳）。
- 每个端点跑 **3 次取中位数**，避免单次抖动误判。
- 改端点：编辑脚本顶部 `TARGETS = [(展示名, 书源key, url), ...]`。
- 判读要点：
  - `跳转 > 0` 且 TTFB 明显偏高 → **书源里写死了会 301 的旧域名**，改成 Location 里的最终域名。
  - `DNS` 单独高（>200ms）→ 本地 DNS 问题，换 DoH/公共 DNS。
  - `TLS` 明显大于 `TCP` → 站点证书链长或走了远节点（如 `CF-RAY: *-LAX` 表示绕美国）。
  - HTTP 4xx 但 TCP/TLS 正常 → 域名可达，只是路径不对（如根路径 404），**不代表源不可用**，看延迟即可。
- 注意：脚本**关闭了证书校验**（`verify_mode = CERT_NONE`），所以证书过期的站点（如 2026-09 的 warchina）在脚本里会显示 OK，但 App 里会失败。判断证书问题要用 `curl -v` 单独确认。

### 2026-09-01 实测基线（本机网络，端到端口径，3 次中位数）

| # | 端点 | 建连成本 | 端到端总耗时 | 备注 |
|---|---|---|---|---|
| 1 | 虫虫漫画 warchina | 124 | **306** | 最快，但**证书已过期**，App 内可能不可用 |
| 2 | 禁漫 cdnsha | 306 | 546 | 可用，推荐首选线路 |
| 3 | 禁漫 cdnntr | 317 | 569 | 同上 |
| 4 | 拷贝漫画 api | 438 | 894 | 波动大（同日另一次测到 2055ms） |
| 5 | 包子漫画 | 444 | 899 | |
| 6 | 禁漫 cdntwice | 469 | 946 | 返回 403，仅测连通性 |
| 7 | 漫蛙吧 manwari（新） | 465 | 963 | **修复后的值** |
| 8 | hitomi 主域 | 504 | 990 | tagindex.hitomi.la 连不上 |
| 9 | 禁漫 图床 | 470 | 1023 | |
| 10 | 漫蛙吧 图床 tu.mhttu.cc | 497 | 1048 | 根路径 403，正常 |
| 11 | 漫画柜 cf.mhgui.com | 554 | 1081 | 主站 www.manhuagui.com **完全连不上** |
| 12 | 漫蛙吧 manwali（旧） | **979** | **1995** | **1 跳 301 → 已修复** |

结论：漫蛙吧旧域名的建连成本 979ms ≈ 别人的 2 倍，全部来自那次 301 跳转（两跳握手）。改域名后 963ms，回到正常水平。

## 15. 全源优化盘点（2026-09-01 第二轮）

接第 14 节测速。对排行上其余各源逐一探测「能否优化」，结论：

### 禁漫 jm（已改，v1.4.2）

- **默认线路是坏的**：`fallbackServers` 旧顺序把 `cdntwice` 排第一当默认（settings `apiDomain` 默认 `'1'`），实测 `/categories/filter` 真实 API：cdntwice **1020ms 且 HTTP 404**（不是慢，是坏）；cdnsha 510ms ✅；cdnntr 571ms ✅；cdnaspa **DNS 解析失败**。
- 改动：① `fallbackServers` 按实测速度重排为 `[cdnsha, cdnntr, cdntwice, cdnaspa]`，默认用户 1020ms→510ms 且从「坏」变「好」；② **apiDomains 无静态初值修复**：`JM.apiDomains` 此前全靠 `refreshApiDomains` 动态赋值，刷新链路任何一环失败（newsvr 拉取失败 / 用户关闭开关）`baseUrl` 就是 `undefined[index]` TypeError 整源不可用，`baseUrl`/`logout` 现已兜底 `|| JM.fallbackServers`。
- 注意 `refreshDomainsOnStart` 默认 true 且会拉 newsvr 动态列表覆盖 fallback（本次实测拉回了 `www.cdnhjk.net` 等新线路），所以此修复主要救两类用户：刷新失败的和关掉开关的。
- 改动文件：`book source/jm.js` + `assets/sources/jm.js`（两份同步）+ index.json version。

### 包子漫画 baozi（确认无优化空间）

- 书源层已是单请求模式（章节内嵌 HTML），没有请求次数可省。
- **6 个候选主域名实测（12 组 lang×domain，`book source/bench_domains.py`）**：当前默认 `cn.bzmgcn.com`（571ms）就是最快的，第二名 `cn.baozimhcn.com` 656ms，其余 900-3000ms。默认已最优。
- CDN 图床 `ascn-a3.bzcdn.net` / `asgb-a3.bzcdn.net` 已 DNS 失效（settings 里还挂着，用户选了会坏）；默认「跟随原始域名」仍是最合理配置。
- 899ms 是站点本身响应速度，动不了。live 测试另暴露其 `loadEp` 403（图片防盗链），属官方源既有问题。

### 拷贝漫画 copy_manga（官方源，不魔改，仅记录）

- 有两处可优化但违反「官方源不本地魔改」约定（第 13 节）：①章节分页 `limit=100` 串行 while 循环（可探测 total 后并发）；②region≠0 时 `getReqID` 是串行额外请求。官方如果更新可提 PR 或对照升级。
- 本机网络对 copy API 不稳（init 阶段 ECONNRESET），live 测试受限。

### hitomi / 漫画柜（无能为力档）

- hitomi：域名固定（ltn.gold-usergeneratedcontent.net），tagindex 子域连不上，gg.js 在本机网络下拿不全。请求模式本身已用 Promise.all。
- 漫画柜：主站 www.manhuagui.com 完全连不上（第 14 节已录）。
- 这两个源的问题全是网络可达性，不是书源逻辑。

### 书源测试器升级（本轮为跑通 jm/copy/hitomi 补的 mock，一次性记录）

- `Convert` 全量真实现（node:crypto）：md5/sha*/aes-ecb/aes-cbc（**不去 padding**，与 Dart ECBBlockCipher 行为一致）/hmac/hmacString/编码转换。jm 的签名头与 newsvr 解密、copy 的 hmacString 签名都依赖它。
- `randomInt`（copy_manga 设备信息生成用）、`Network.fetchBytes`（hitomi 二进制分片用，**body 必须返回 ArrayBuffer**，因为 hitomi 直接 `new DataView(res.body)`；Uint8Array 会 TypeError）。
- `init()` 必须 `await`（jm 的 init 是 async 且有网络副作用，不 await 的话失败变成 unhandled rejection，后续全链路莫名崩溃）。
- 跨 vm `instanceof Map` 恒为 false（构造函数跨 realm 不同），spread/for...of 同样失效（Symbol.iterator 跨 realm 不通用）——用鸭式 `isMap`（get/forEach/size）+ `forEach` 遍历。

## 16. 漫网 manwang.net 新源（2026-10-04）

用户给 `https://www.manwang.net/book/507169` 要求做书源。产出 `book source/manwang.js` + `assets/sources/manwang.js`（两份同步）+ index.json v1.0.0。测试器 live **13/14**（唯一失败项是站点自身搜索失效）。

### 站点结构（纯 HTML，无可用 API）

| 用途 | URL | 实测 |
|---|---|---|
| 最近更新 | `/custom/update/page/{n}/` | 30 本/页 |
| 分类 | `/category/tags/{tagId}/page/{n}/` | 30 本/页，分页条尾页 50 |
| 详情 | `/book/{comicId}` | 章节全在页内，**无章节分页接口**（1328 章的元尊也是一次全出） |
| 章节 | `/chapter/{comicId}-{chapterId}` | 图片列表在加密 params 里 |

分页 URL 格式坑：`?page=2`、`/2`、`/tags/2585-2` **全都无效**（静默返回第 1 页，size 一字不差），只有 `/page/2/`（带尾斜杠）真分页。第 1 页用不带 `/page/1/` 的形式。

### 图片解密（核心难点）

章节页 `var tpl_path='…', params='<base64>'`，由 `/template/pc/33/js/pic-v2.js` 的 `decryptParams()` 解密。该 js 是 jsjiami 混淆 + 数组自轮转，**静态解混淆不可行**（`_0x392f` 字符串表带 IIFE 轮转），必须真跑。做法：Node + `vm` 起 sandbox，shim 掉 `$`（**要收集 ready 回调延后执行**，立即执行会因 `params` 未定义抛 "Unexpected end of JSON input" 并中断整个文件），注入 CryptoJS，`hook CryptoJS.AES.decrypt` 抓 key/iv。

**最终算法（纯 Node crypto 独立复现验证）**：
```
key  = '9S8$vJnU2ANeSRoF'            (16 字节 ASCII → AES-128)
raw  = base64decode(params)
iv   = raw[0:16]
ct   = raw[16:]
→ AES-128-CBC 解密 → UTF-8 → JSON{host, source_id, comic_id, chapter_id, images[]}
```
5 本书 × 首/中/末章共 7 次解密全部通过，单章 50~216 张。

**两个把人带沟里的假线索**：
1. **hook 出来的 iv 是 64 字节，照抄必炸**。那 64 字节 = `iv[16:]` 与 `ct` 前 48 字节的重叠（CBC 解密只用 iv 前 16 字节，混淆代码 `slice(0,0x10)` 的 0x10 是 16 个 **word** 不是字节… 实测按 16 字节切才对）。按 64 字节传给 `createDecipheriv` 直接 `Invalid initialization vector`。
2. `source_id == 12` 才走 `decryptImage` 的图片级 AES 解密且需换域名 `img1.baipiaoguai.org`；本源实测 `source_id == 15`，**图片是明文 WebP，不需要任何图片解密**。别被 `mwp` 兜底数组误导。

### 图片防盗链（硬性）

图床只有 `dmw.546457.xyz`（采样 471 张全是它）。**必须带 `Referer: https://www.manwang.net/`**（站点根，不能带路径）才 200：
- 无 referer → 403 text/html
- `Referer: https://example.com/` → 403（不是"有 referer 就行"，是白名单）
- 正确 referer → 200 image/webp

书源侧写在 `comic.onImageLoad` 返回的 `headers` 里。

### 传字节给 Dart 的坑（复用价值高）

Dart 端 `Convert.decryptAesCbc`（`js_engine.dart` aes-cbc 分支）走 `CBCBlockCipher.processBlock`，**只认 Uint8List 且不去 PKCS#7 padding**。两条铁律：
1. **必须传 `.buffer`（ArrayBuffer）**。普通数组→`List<dynamic>`、Uint8Array→`Map`，都报类型错。
2. **绝不能把字节拼成 String 再传**。字节 ≥0x80 时 JS 字符串按 UTF-16 存，接收侧取字节按 UTF-8 重编码 → 长度膨胀 → IV 直接失效。最初就是 `String.fromCharCode` 拼 latin1 串，症状是 `Invalid initialization vector`（长度不对，不是密钥不对，**别往密钥方向查**）。
3. 返回值尾部带 padding，**必须自己剥**（末字节 = N 则末尾 N 字节都是 N），否则 `JSON.parse` 直接抛。

书源里写成：优先 `sendMessage`（App 真实路径），`typeof sendMessage !== 'function'` 时降级 `Convert.decryptAesCbc`，两条都传 `.buffer`。这样 App 和测试器都能跑。

### 分类表：必须运行时动态抓

站点有 **601 个标签**，id 与名称**无法凭直觉对应**——2583 是「编剧」不是「恋爱」、2585 才是「玄幻」。猜 id 全错。
`init()` 里抓 `/category` 页的 `<a href="/category/tags/{id}">{name}</a>` 建 `tagCache`，同 id 多次出现取首个，然后写回 `category.parts[0].categories`（名称）与 `.categoryParams`（id，两者**严格一一对应**）。
时序安全性：App 在 `parser.dart:174` 用 `Future.delayed(50ms)` 调 `init()`，分类页打开远晚于此；且 `fallbackTags` 兜底 12 项，抓取失败也不会空。
各分类内容量差异极大：玄幻/系统/穿越/热血 30 部，但**恋爱(2617) 只有 3 部、都市 4 部、搞笑 14 部**——不是解析漏了，是站点内容就少（实测 grep 计数确认）。

### 站点自身的问题（不是书源 bug，别去"修"）

- **站内搜索彻底失效**：`/search/{kw}`、`/search?keyword=`、`/index.php/search?key=`（GET/POST 全试）对任意书名一律返回「搜索结果（0）」，索引已废。故 `search.load` 直接抛可读错误，不静默返回空。
- **大量书已下架**：`/book/{id}` → 302 → `/err/comic`（165 字节错误页），热门老书居多（狐妖小红娘 501660、王牌御史 503737、武炼巅峰 500907…）。16 本抽样里 4 本下架。
  ⚠️ **App 的 `Network.get` 自动跟随 3xx**，所以 `res.status` 永远看不到 302，拿到的是「200 + 错误页 body」。只按 status 判会误报"结构可能已变"。必须再按 body 特征兜底：`body.length < 600 && !body.includes('detail-title')` → 判下架。

### 验证结果

玄幻 + 奇幻各抽 8 本共 16 本：12 本可用（每本抽首/中/末 3 章解密 + 首图 HTTP 200 校验，共 36 次图片下载全通过，累计解密 2246 张图）、4 本站点下架（正确识别）、0 失败。

## 17. 虫虫漫画搜索修复 + 从异次元图源库挖站（2026-10-04）

### 17.1 虫虫 warchina 搜索为什么永远返回同一个东西
**根因：书源用的端点根本不存在，站点搜索后端已被官方关闭。**

旧代码 `this.baseUrl + '/search?keyword=' + kw` —— 实测这个端点**根本不读 keyword**：

| 关键词 | 返回字节 | 漫画数 |
|---|---|---|
| 海贼王 | 59403 | 84 |
| 火影忍者 | 59403 | 84 |
| 鬼灭之刃 | 59403 | 84 |
| zzz不存在 | 59403 | 84 |

那 84 本全来自页面里的「JJ韩漫更新」「更新排行」等**推荐位**，`/search?keyword=` 实际是**首页镜像**。

**真实端点**（从 `statics/js/b.min.js` 的 `All.S()` 逆向）：
```
/statics/search.aspx?key=<encodeURIComponent(kw)>     ← 参数名是 key 不是 keyword
```
但该端点 HTTP 200、`<title>` 正确变成「搜索XX相关的漫画」，**结果容器 `<div class="clearfix"></div>` 是空的**。
JS 里明写 `if (All.P=="2"){ alert("您好，搜索功能暂时关闭!"); return false; }` → **站点已关闭搜索**。

**修法（v1.0.3）：全库索引 + 客户端精筛**
- 分页 `/comic/{n}.html`（30 本/页）。**`/comic/?page=2` 是假的**，每页都返回同样 30 本。
- `p>=100` 返回 404 首页（84 本推荐位），上限 99，实测**全库 2333 本**。
- 越界页用 `cards.length > 60` 挡掉防污染。
- `search.load` 两级：① 先试真实端点（站点万一恢复就命中）② 兜底抓全库按标题 AND 匹配。
- 24 小时索引缓存（`saveData('index', {d, l:[[id,title,cover]]})`）。
- 实测：搜索「高校传说」→ 1 条精确命中，41 章，81 张图。
- ⚠️ 虫虫是**纯韩漫库**，搜「海贼王」返回 0 是正常的。
- ⚠️ 虫虫证书 2026-08-20 已过期，需开 `设置→调试→ignoreBadCertificate`。

### 17.2 分页参数拼错不会 404，只会静默返回第 1 页（跨站规律）
- warchina: `/comic/{n}.html` ✅ / `/comic/?page=n` ❌
- manwang: `/page/{n}/` ✅（带尾斜杠）/ `?page=n` ❌ / `/n` ❌

**测分页必须比对不同页的字节数是否相同**，只看 status 判不出来。

### 17.3 从异次元图源库挖真实域名（别再猜域名）
猜域名 vs 社区维护的图源库，效果差 3.5 倍：

| 来源 | 域名数 | 搜索真生效 |
|---|---|---|
| 瞎猜（两轮） | 95 | 4（全是正版） |
| 异次元图源库 | 222 | **14** |

**数据源**：`https://gcore.jsdelivr.net/gh/yiciyuan123/yiciyuan/<合集名>.json`
合集名：`weiguanfang` / `sanyuetuyuan` / `siyuetuyuan` / `eryuetuyuan` / `shougongxiaojian` /
`yiciyuantuyuan` / `qishiliu` / `bayuezuixintuyuan` / `ershisantuyuan`

⚠️ 三个必知点：
1. 文件是 **base64 + zlib 双重编码** → `base64.b64decode` → `zlib.decompress` → `json.loads`。
   直接 `json.load` 报 `Expecting value: line 1 column 1`。
2. 每条含 `bookSourceUrl`（站点域名）+ `ruleSearchUrl`（**含真实参数名**，如 `search_key=` / `title=` / `key=`）。
3. **解析规则里的选择器是加密的**（`:_H006_xxx==`），读不出明文 —— 只能用端点，不能抄规则。

**GitHub 官方域名（api.github.com / raw.githubusercontent.com）本机被墙**，走 jsDelivr 通。
venera 的 fork 仓（ikznbfin/nekoqwq/Maplespe）已全部 404。

### 17.4 HTTP 探测的三个坑（都误判过）
1. **chunked + gzip 双重编码**：部分站同时发 `Transfer-Encoding: chunked` + `Content-Encoding: gzip`。
   裸 socket 读到的 body 前缀是 chunk 头 `1f0f\r\n` 再跟 gzip magic `1f8b`。
   只按 Content-Encoding 解压会失败 → **全文匹配恒为 0**，把有数据的站误判成"没数据"（我误判了 3 轮）。
   必须先剥 chunked 帧再 gzip 解压。
2. **重定向伪装成功**：`/comic/107477` → 301 → `/comic/107477/`(404)，跟随后拿到**首页**，
   首页里当然"有 79 个章节链接"——全是假的。**验详情页必须看重定向前的状态码**。
3. **中文路径必须 quote()**，否则 socket 层直接连接失败。

### 17.5 判断站能不能当书源的唯一可靠判据
**同关键词 vs 乱码关键词，两次响应必须不同。** 光看首页 200 没用：

| 站点 | 搜「海贼王」 | 搜乱码 | 结论 |
|---|---|---|---|
| 次元仓 | 1000B | 1000B | 搜索是废的 |
| 漫本 | 12050B | 12050B | 搜索是废的 |
| K漫画 | 8954B | 8954B | 搜索是废的 |
| 幻书阁 | 196B | 196B | 域名停放卖钱 |

**工具**：`book source/probe_yciyuan.py`（解合集提域名）/ `probe_ycy_final.py`（终判，带 dechunk）/ `probe_ycy_chain.py`（全链路）
**结果**：`book source/YCY_FINDINGS.md`（14 站端点清单 + API 模板）

### 17.6 ★ 漫画屋 mhua5.com 新源（v1.0.0，测试器 14/14 全通过）
免费国漫站，图床是包子漫画的 `s*.baozimh.com`。

```
搜索  /index.php/search/{kw}          （也支持 ?key=）
详情  /index.php/comic/{slug}         slug 是拼音，如 haizeiwangaisi
章节  /index.php/chapter/{数字id}
分类  /index.php/category/tags/{id}   26 个，id 从首页导航动态抓
```

实测：搜索「海贼王」6 条 → loadInfo《海贼王 艾斯》4 章 → loadEp 50 张 → 图片 747923B magic=ffd8ffe00010。

**三个 HTML 陷阱**（照抄通用）：
1. `<a class="cover">` 上**没有 title 属性**，书名在 `<img alt=" 海贼王 艾斯 ">`（**前后有空格要 trim**）。
2. 真封面在 **`data-original`**，`src` 是 `bg_loadimg_3x4.png` 占位图。
3. 章节页 img 数量**含推荐位**，按 `/scomic/` 路径过滤才准（该章真实 50 张，页面 66 个 img）。

### 17.7 看漫/漫画台系 API 模板（备选，尚未做成源）
`m.manhuatai.com`(mht) / `m.kanman.com`(kmh) / `m.isamanhua.com`(samh) /
`m.iyouman.com`(iymh) / `m.taomanhua.com`(tmh) 是**同一套 API 模板**，只差 `productname`：

```
搜索 /api/getsortlist/?search_key={kw}&page=1&size=30&productname={PN}&platformname=wap
  → {data:{page:{count,total_page}, data:[{comic_id,comic_name,comic_author,comic_desc,
     last_chapter_name,update_time,shoucang,renqi}]}}
详情 /api/getcomicinfo_body?comic_id={id}&productname={PN}&platformname=wap
  → {data:{comic_name,comic_author,comic_desc,comic_chapter:[627章],last_chapter_id,...}}
章节 comic_chapter[] 每项：{chapter_name,chapter_id,chapter_topic_id,chapter_domain,
     rule:"/comic/M/{书名}/第613话F0_393471/$$.jpg",islock,price,start_num,end_num}
```
实测 `kanman comic_id=107477` → 224KB / 627 章。

⚠️ **卡在图片这步**：`dm300.com` 图床活着（HTTP 200），但 `$$` 替换成 `1.jpg` 实请求 **404**。
真实页码格式在异次元的加密选择器里，要继续必须逆向。

### 17.8 书源测试器本轮修的两处
1. **id 配对**（记忆里 9 月就记过，今天真修）：`firstComic` 取自 category 列表、`firstEpId` 取自另一本书
   → `/chapter/{A}-{B}` 必 404。修法：`const pairedComic = chosen || candidates[0] || firstComic;`
2. **候选顺序**：`[firstComic, searchFirst, exploreFirst]` 改成 `[searchFirst, firstComic, exploreFirst]`。
   否则「搜 A 的词、却验 explore 里 B 的章节」，源没问题也误报 loadEp 失败。
3. 顺带：图片校验原来固定 `fetch(ep.images[0])`，**绕过了 onImageLoad 的图床改写**。
   现在解析 `cfg.img || cfg.imageUrl || cfg.url || cfg.src` 并校验 `size>1500 && magic 是 ffd8/8950/WEBP`。

## 18. 酷笔漫画 kubb.cc 新源（v1.0.0，测试器 14/14 全通过）

用户提供 `https://www.kubb.cc/user/login`，实测可用并做成书源。

### 18.1 ★ 最特殊的坑：按 UA 分流，桌面 UA 一律 403
```
桌面 Chrome UA → 403 Forbidden（nginx 层，915 字节）
iPhone Safari UA → 200（46KB）
```
**书源 headers 里必须写 iPhone UA**，改成桌面 UA 这个源直接死。带 cookie 复访也无效（纯 UA 判定）。

### 18.2 站点结构
```
全部分类 : /dir/0/0/1/1?page=N      每页 30 本，?page= 有效
分类树   : /dir/{a}/{b}/{c}/{d}      第 4 段是排序(1=最新 2=热门)
漫画详情 : /byf/{书拼音}.html        ← 详情与分类同路径格式
章节     : /evf/{书拼音}/{章节拼音}.html
图片     : 章节页 <img src="https://{p|t}.wx4.top/...">，WebP 直链
404 页   : 带 <meta http-equiv="refresh" content="2; url=/">，会自动跳首页
```

### 18.3 站点没有搜索功能
`/search` `/search.html` `/so` `/find` `/ss` `/sitemap` 全 404，JS（base.js / s.js / t.js）里也没有搜索端点。
`sitemap/comic/{n}.xml` 是**无限分片**（每片 2000 条）且**只有拼音 URL 没有书名**，不能用来建索引。

**替代方案**：`search.load` 抓 `/dir/0/0/1/1?page=1..30` 建全库索引（30×30=900 本），
按书名客户端筛选，缓存 24h（`saveData('index', {d, l:[[slug,title]]})`）。
实测「鬼」→12 本、「狼」→5 本、乱码 →0 本。

### 18.4 详情页用标准 Open Graph 漫画协议（字段很好解析）
```
og:comic:book_name / og:comic:author / og:comic:category / og:comic:status
og:comic:update_time / og:comic:latest_chapter_name / og:comic:latest_chapter_url
og:image / og:description
```
比解析正文稳。注意 `og:title` 前面会带《》和「(下拉式观看)」，要用 `og:comic:book_name` 才是纯书名。
书名里常有 HTML 实体（`&#43;` `&#x...;`），要反转义。

### 18.5 图床两个坑
1. **子域名不固定**：`p.wx4.top` 和 `t.wx4.top` 都见过 → 必须匹配整个 `wx4.top` 域，不能写死 `p.`。
2. **文件名是哈希无页码**（`1669065588bf604042da50d06f239d6f_zb.webp`）→
   **不能按数字排序**，HTML 里的出现顺序就是正确阅读顺序。
   （对比 mhua5 的 `1.jpg 2.jpg` 就有页码可以排序 —— 别混了这两种。）

实测 62KB~435KB/张，**不校验 referer**（带与不带都是 200），magic=RIFF（真 WebP）。

### 18.6 当前书源清单（10 个）
| 源 | key | 版本 | 状态 |
|---|---|---|---|
| 拷贝漫画 | copy_manga | 1.4.1 | 官方源，超时 |
| 包子漫画 | baozi | 1.2.0 | 403（需完整浏览器 UA+referer） |
| 禁漫天堂 | jm | 1.4.5 | ✅ 13/14 |
| hitomi.la | hitomi | 1.1.2 | 本机超时 |
| 漫蛙吧 | manwaba | 1.4.0 | ✅ 13/14 |
| 虫虫漫画 | warchina | 1.0.3 | ✅ 12/13（需开证书忽略） |
| 漫画柜 | ManHuaGui | 1.2.1 | 连接超时 |
| 漫网 | manwang | 1.0.0 | ✅ 13/14（站内搜索已废） |
| **漫画屋** | **mhua5** | **1.0.0** | ✅ **14/14**（新） |
| **酷笔漫画** | **kubb** | **1.0.0** | ✅ **14/14**（新） |

## 19. ★★ category 结构契约（写书源必看，踩过两次）

**App 里分类页能不能显示，完全取决于 `category` 对象结构对不对。结构错了测试照样「全过」，
但 App 分类页一个分类都不显示。** 2026-10-04 踩了这个坑：
mhua5 和 kubb 报「14/14 全通过」，实际分类页是空的。

### 19.1 App 的硬性要求（`lib/foundation/comic_source/parser.dart:430` `_loadCategoryData()`）
```js
category = {
  title: this.name,        // ① 必填字符串！缺了直接 return null，整个分类页看不到这个源
  parts: [{
    name: '分类组名',       // ② 是 name，不是 title
    type: 'fixed',         // ③ 必须是 fixed / random / dynamic
    itemType: 'category',  // ④ 旧格式必填，否则 PageJumpTarget 拿不到跳转目标 → 点了没反应
    categories: ['全部', '热血', ...],
    categoryParams: ['0', '6', ...],   // ⑤ 与 categories 长度必须严格相等，否则参数错位
  }],
  enableRankingPage: false,
}
```
只有 ① 缺了会被**静默丢弃**（返回 null），不报错不打日志——最难查的一种。
②③④ 缺了会走到 `parser.dart:503` 的 else 分支，target 传 null，分类项点不动。

正确范例见 `book source/manwaba.js` 的 `category`。

### 19.2 为什么分类名要硬编码，不能运行时抓
App 在 `parser.dart:174` 是 `runCode("...init()")` —— **同步调用，不 await Promise**，
紧接着就同步解析 `category`。所以：
- 在 `init()` 里异步抓分类 → **来不及**，首次进分类页仍只有第一项
- 在 `categoryComics.load` 里抓 → 首次点分类也是空的

**正确做法**：硬编码实测的完整分类列表（名称 + param 两数组一一对应），
再留一个 `ensureCategories()` 在打开分类页时异步刷新，**抓到更多才覆盖**（防止站点临时异常导致分类变少）。

### 19.3 测试器已补的两道防线
1. **`book_source_test.mjs` 新增 `category 结构契约（App 渲染前提）`** ——
   照 `_loadCategoryData()` 逐条校验 ①~⑤，并在通过时打印分类项数与前几项名称。
2. **新增 `test/book_source_test/cat_test.mjs`** —— 联调 `category` + `categoryComics`，
   实际去点 4 个分类项（第 0/1/中间/最后），看能不能真加载出漫画。
   ```bash
   node cat_test.mjs "../../book source/kubb.js"
   ```
   写这个脚本时踩的 mock 坑（都已在文件里注释）：
   - `HtmlDocument` 必须是**类**（书源写 `new HtmlDocument(html)`），不能是 `{create}` 对象
   - `querySelectorAll` 必须返回**真数组**（length + 数字下标），返回包装对象会在
     `for (let a of doc.querySelectorAll('a'))` 上死循环
   - `Network.get` 返回 **`{status}`** 不是 `{statusCode}`，书源判断 `res.status`
   - `Network.sendRequest` 签名是 `(method, url, headers, data, extra)`（`assets/init.js:498`），
     manwaba 等源走这个，不 mock 就报 `Network.sendRequest is not a function`

### 19.4 分类页空 ≠ 书源 bug
实测 mhua5 的「耽美(16)」「百合(27)」返回 0 本：直接 curl 站点，
`tags/27` 标题正确、页面 26KB、**0 张漫画卡片** —— 是站点该分类本来就没书。
遇到 0 本先 curl 确认，别急着改解析逻辑。
