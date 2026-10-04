# 异次元图源挖掘结果（2026-10-04）

## 数据源
- 仓库：`yiciyuan123/yiciyuan`（jsDelivr: `gcore.jsdelivr.net/gh/yiciyuan123/yiciyuan/<name>.json`）
- 格式：**base64 + zlib 双重编码**的 JSON（`base64decode → zlib.decompress → json.loads`）
- 已下 9 个合集，条目去重后 **1000+ 个图源**，聚合出 **222 个不重复站点**
- 每个图源含 `bookSourceUrl`（站点域名）+ `ruleSearchUrl`（搜索端点）+ 完整解析规则
- ⚠️ 解析规则里的选择器是**加密的**（`:_H006_xxx==`），读不出明文，只能用端点

## 测速结果对比（关键结论）
| 来源 | 域名数 | 搜索真生效 |
|---|---|---|
| 我瞎猜（两轮） | 95 | 4（且全是正版） |
| 异次元图源库 | 222 | **14** |

## 14 个搜索真实生效的站
| host | hits | 搜索端点 | 备注 |
|---|---|---|---|
| www.1kkk.com | 31 | `http://www.1kkk.com/search?title={kw}&language=1&page=searchPage` | 极速漫画，HTML 解析 |
| m.manhuatai.com | 30 | `https://m.manhuatai.com/api/getsortlist/?search_key={kw}&page=searchPage&size=30&productname=mht&platformname=wap` | JSON API，count=131 |
| m.taomanhua.com | 30 | 同上，productname=tmh | JSON API |
| m.isamanhua.com | 30 | 同上，productname=samh | JSON API |
| m.iyouman.com | 30 | 同上，productname=iymh | JSON API |
| cn.bzmanga.com | 22 | `https://cn.bzmanga.com/search?q={kw}` | 包子漫画 SSR |
| cn.webmota.com | 22 | `https://cn.webmota.com/search?q={kw}` | 同 bzmanga 同架构 |
| m.kanman.com | 14 | `.../api/getsortlist/?product_id=1&search_key={kw}&...&productname=kmh` | JSON API |
| www.dongman.la | 13 | `https://www.dongman.la/manhua/so/{kw}/searchPage.html` | |
| www.mhua5.com | 12 | `https://www.mhua5.com/index.php/search?key={kw}` | **章节页 65 张图可用** |
| www.dingmanhua.com | 3 | `https://www.dingmanhua.com/search/?query={kw}&page=searchPage` | |
| www.jdlingyu.com | 3 | `https://www.jdlingyu.com/?s={kw}&post_type=post` | **章节页 21 张图可用** |
| getconfig-globalapi.yyhao.com | 30 | `/app_api/v5/getsortlist` | 纯 API 无网页，排除 |
| www.duitang.com | 74 | `/napi/blog/list/by_search/` | 图集站非漫画，排除 |

## ★ 最有价值的发现：看漫/漫画台系 API 三件套
`m.manhuatai.com` / `m.kanman.com` / `m.isamanhua.com` / `m.iyouman.com` / `m.taomanhua.com`
是**同一套 API 模板**（`productname` 不同而已），实测可用：

```
搜索：/api/getsortlist/?search_key={kw}&page=1&size=30&productname={PN}&platformname=wap
  → {data:{page:{count,total_page}, data:[{comic_id, comic_name, comic_author,
     comic_desc, last_chapter_name, update_time, shoucang, renqi}]}}

详情：/api/getcomicinfo_body?comic_id={id}&productname={PN}&platformname=wap
  → {data:{comic_name, comic_author, comic_desc, comic_chapter:[627章],
     last_chapter_id, comic_media, update_time, ...}}
     实测 kanman comic_id=107477 → 224KB / 627 章

章节：comic_chapter[] 每项含
  {chapter_name, chapter_id:"di613hua-1683957030", chapter_topic_id, chapter_domain,
   rule:"/comic/M/{书名}/第613话F0_393471/$$.jpg", islock, price, start_num, end_num}
  → 图片 = https://{chapter_domain}{rule} 中 $$ 替换为页码
```

**⚠️ 卡在这一步**：`dm300.com` 图床本身活着（HTTP 200），但 `$$` 替换成 `1.jpg` 实际请求返回 **404**。
真正的页码格式/加密逻辑在异次元的加密选择器里（`:_H006_`），**需要逆向才能继续**。

## 三个关键技术坑（都踩了）
1. **双重编码**：这些站同时发 `Transfer-Encoding: chunked` + `Content-Encoding: gzip`。
   裸 socket 读到的 body 前缀是 chunk 头 `1f0f\r\n` 再跟 gzip magic `1f8b`。
   只按 Content-Encoding 解压会失败 → **全文匹配恒为 0**，误判成"站点没数据"。
   必须先剥 chunked 帧再 gzip 解压。（`probe_ycy_final.py` 的 `dechunk()`）
2. **base64+zlib**：合集文件不能直接 json.load，要先 `base64.b64decode` 再 `zlib.decompress`。
3. **重定向伪装成功**：`/comic/107477` 301 到 `/comic/107477/`（404），
   跟随重定向后拿到的是**首页**，里面当然"有 79 个章节链接"——全是假的。
   验详情页必须看**重定向前的状态码**。

## 可用工具
- `probe_yciyuan.py` — 解合集、提域名、并发快筛（222 站）
- `probe_ycy_deep.py` — 中层：搜索端点真假验证
- `probe_ycy_final.py` — 终判：真关键词 vs 乱词对照（带 dechunk 修复）
- `probe_ycy_chain.py` — 全链路：搜索→详情→章节→图片
- 产出：`ycy_sites.json` / `ycy_deep.json` / `ycy_final.json` / `ycy_chain.json` / `ycy_summary.json`
