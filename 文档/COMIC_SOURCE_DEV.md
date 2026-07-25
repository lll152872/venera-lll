# 书源（Comic Source）开发注意事项

> 从 `BUILD_NOTES.md` 拆分。书源 `.js` 文件**不要 push 进主仓库**（属本地私有内容，不应进入公共仓库）。

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
