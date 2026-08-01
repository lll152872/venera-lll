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
- **卡片正则**：详情页链接用 `/\/comic\/(\d+)\/?$/`（结尾锚定，自动排除章节 `.html` 链接）。
