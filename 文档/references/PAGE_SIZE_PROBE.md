# 连续滚动：跳转落点精度方案（读文件头拿真实页高）

> **状态**：**已实现并本地验证**（2026-10-25）。
> 起因：用户报「点进度条后内容跳了但页码/滑块不动」。页码那半已修（见文末「已修部分」），
> 剩下的「落点不准」是独立问题，本文档记录根因、数据、实施方案与实测结果。
> 配套：`../0_必看.md`（任务路由）、`TESTING.md`（测试命令）、`BUILD_WINDOWS.md`（本地构建）。

---

## 一、问题：为什么「点第 N 页」不能精确落在第 N 页

### 1.1 前提澄清（容易误解的两点）

- 进度条**已经**是按页均匀划分的：`divisions = maxPage - 1`，
  点击 x → `round(dx / gap) + 1` → 整数页（`lib/components/custom_slider.dart`）。
- 点击**已经**是「直接移动到页」：`onChanged → context.reader.toPage(N)`
  （`lib/pages/reader/scaffold.dart` 的 `buildSlider`）。

所以问题**不在滑块**，而在「第 N 页」在连续滚动里**没有固定的像素位置**。

### 1.2 根因

- 每页高度 = 图片高宽比 × 显示宽：
  `_computeAxisSize(imgW, imgH)`（`lib/pages/reader/images.dart`），
  垂直模式下 `cellSize = _layoutCrossAxis`（图片显示宽，`limitImageWidth` 开启时
  被压到 `视口高 × 0.7`）。
- **图片加载前，这个高度不存在**（要等解码拿到像素尺寸）。
- 未加载的页在 `_pageHeights` 里回退到 `_placeholderPageHeight = reader.size.height`
  （**视口高**，纯占位值）。
- 跳转偏移 = `_offsetForGp(gp) = Σ_{i<gp} (pageHeight(i) + kPageSpacing)`，
  即**逐页累加高度**。

⇒ **要把第 N 页放到视口顶，必须知道第 1..N-1 页各多高。**
未知的部分用占位高硬估 ⇒ 落点偏移。页数是准的，像素不是。

### 1.3 为什么「估不准」（本机实测数据）

数据源：`%APPDATA%/com.github.wgh136/venera/image_sizes.json`（3136 张已解码图的真实像素尺寸）。

页面高宽比分布：p10 = 0.50，中位 = 1.50，p90 = 4.00（长条漫画）。
按用户窗口（视口约 1280×1208，图宽 = min(1280, 1208×0.7) = 845，占位高 = 1208）：

| 页型 | 高宽比 | 真实页高 | 占位高 | 单页误差 | 跳 20 页的偏差 |
|---|---|---|---|---|---|
| 短横页 (p10) | 0.50 | 423 | 1208 | −785 | 偏 **37 页**（冲过头） |
| 典型页 (中位) | 1.50 | 1268 | 1208 | +60 | 偏 **1 页**（几乎无感） |
| 长条页 (p90) | 4.00 | 3382 | 1208 | +2174 | 偏 **13 页** |

**结论：误差与漫画页型强相关，不能用固定占位值或章内平均高度糊弄**
（章内方差的样本量不足：缓存里只有 6 个章目录有 ≥5 页，中位 RSD=0.023 不具代表性）。

---

## 二、方案 A：读图片文件头拿真实宽高（已实现）

### 2.1 思路

宽高就写在图片**文件头**里，只读前 64KB 就能解析，**不需要解码整图**：

| 格式 | 头信息位置 |
|---|---|
| WebP | `RIFF....WEBP` + `VP8X`（24-29 字节，宽高各 24bit LE）/ `VP8L`（bit 布局）/ `VP8 `（帧头） |
| JPEG | 扫描 `SOF0/1/2/...` 段，取 `height(2B) width(2B)` |
| PNG | `IHDR` 段，宽高各 4B BE |
| GIF | 逻辑屏宽高各 2B LE |
| BMP | DIB 头宽高 |
| AVIF/HEIF | `ispe` box（宽高各 4B BE） |

- **本地已下载的章**：直接读本地文件 → **零网络、零解码**。
- **网络章**：发 `Range: bytes=0-65535` 请求 → 每页一个小请求
  （50 页约 3.2MB，比加载 50 张整图小一个数量级）。
- 探测结果写回现有 `ImageSizeCache` → 跨会话持久化，下次开章直接命中。

### 2.2 接入点

| 位置 | 作用 |
|---|---|
| `lib/foundation/image_size_probe.dart` | **新建**：头解析 + 本地文件读 + Dio Range 请求 |
| `lib/foundation/image_size_cache.dart` | `get/put` 尺寸缓存（探测结果写这里，跨会话复用） |
| `lib/pages/reader/images.dart` `_scheduleSizeProbe()` | 章节就绪后后台探测（并发 3） |
| `lib/pages/reader/images.dart` `_applyProbedSize()` | 探测结果回填 `_pageHeights` |
| `lib/pages/reader/images.dart` `_buildSplicedItem()` | 已知页高直接当 `placeholderHeight`，布局与估算同源 |
| `lib/pages/reader/images.dart` `_SplicedPageDelegate` | 覆写 `estimateMaxScrollOffset`，跳转不再被 clamp |
| `lib/pages/reader/images.dart` `_alignToGp()` | 跳转后按真实布局位置二次校正落点 |

### 2.3 核心不变量：「估算基准 == 真实布局高度」

跳转偏移 = Σ `_pageHeights`，而**落点由各 item 的实际布局高度决定**。
两者必须逐页相等，否则偏移算得再准也落不对。

由此推出两条硬规则（实现里都靠它保证）：

1. **已知页高 → 布局就用它**：`_buildSplicedItem` 把 `placeholderHeight` 取成
   `_pageHeights[index]`（未知才回退占位高）。图片还没解码时 item 就按真实高度
   布局，不会「先占位高、再突变成真实高」把上方内容顶走。
2. **已渲染出来的页不改估算**：探测结果只回填「还没被 build 出来」的页。
   已 build 的页布局高度已是既成事实（占位高或已解码高度），改估算只会让
   两者脱节——等图片解码时 `onImageLoaded` 会同时更新布局和 `_pageHeights`。

> 这两条是整个修复能成立的前提。违反其中任何一条都会让「偏移算对、落点还是偏」。

### 2.4 跳转落点校正（`_alignToGp`）

即便有上述不变量，仍可能有残差（页高异步到位、估算偏太远导致目标页没被 build）。
跳转后按帧核对实际落点，偏差则用两种方式之一修正，最多 3 轮：

- `_alignByRenderBox`：目标页已在渲染树里 → 直接用它的真实布局位置对齐（最准）。
- `_alignByEstimate`：目标页还没被 build → 用「当前落点页的真实位置 + 已知页高」
  重算目标页的像素位置。

期间被新的跳转取代（用户又点了进度条）立即放弃，不跟用户抢。

### 2.5 顺带修掉的两个问题

- **`jumpTo` 被 clamp**：`_SplicedPageDelegate` 默认按「已布局 item 的平均 extent ×
  item 总数」外推总长，页高差异大时算出的 `maxScrollExtent` 偏小 → 跳转被截断。
  覆写成「逐页累加已知高度」后消失。
- **页码在页边界上差 1**：`_currentPageFromViewport` 原先用 `Rect.overlaps` 判可见，
  视口顶边恰好落在页边界时上一页会因浮点误差被判成「可见」且起始边更小 →
  页码显示 N-1。改成「视口在起始端内缩 0.5px」后判定稳定。

### 2.6 验收结果（本地实测）

| 项 | 结果 |
|---|---|
| `test/image_size_probe_test.dart` | 14/14 通过（8 种格式正例 + 6 个异常输入返回 null） |
| `test/reader_jump_precision_test.dart` | 2/2 通过（页高已知 → 跳第 30 页精确落第 30 页；页高未知 → 降级自洽） |
| `flutter analyze` | 无新增 warning / info（基线 13 条 info 未变） |
| `flutter test`（全量） | 49 通过 / 8 失败 = 基线同款（6 条缺原生 DLL：rhttp.dll、flutter_qjs_plugin.dll；2 条 `reader_continuous_scroll_test.dart` 基线红用例，失败形态仍是 300ms pending timer） |

**已知限制**：

1. 从右到左连续滚动（`continuousRightToLeft`）的滚动方向是反的，
   `_offsetForGp` 算的是 sliver 正向偏移、与 `pixels` 差一个总长 → 该模式的跳转
   落点**不在本次修复范围**（垂直 / 从左到右已修）。
2. 探测失败（服务器不支持 Range、图床要 Referer 且拿不到、格式不认识）一律回退
   占位高，不崩不阻塞；此时落点精度退回修复前水平。
3. 探测结果对**已渲染出来的页**不生效（见 §2.3 规则 2），这些页要等图片解码。

---

## 三、已修部分（2026-10-24）

commit `c9e8d50`（CI analyze 由红转绿见 `2ab9b80`）：

1. **页码/滑块不更新**：连续滚动 + 动画模式下 `toPage()` 只写 `_pendingPage` 不写 `page`，
   动画期间视图回传的中间页又被 `setPage()` 守卫全部丢弃；动画结束本该由
   `_syncReaderState()` 校正，但那个函数有「gp 突变 > 15 页就丢弃」的硬拦截
   （跨 15 页以上的跳转必中）→ **页码永久冻结**。
   改法：动画分支先乐观更新 `page`；动画结束调新增的 `syncCurrentPage()`
   （连续模式 `force=true` 绕过 gp 突变拦截）→ 页码按**实际看到的那一页**校正。
2. **滑块只能纵向拖**：原来只有 `onVerticalDragUpdate` → 桌面端横向拖动无反应。
   改用 `onPanUpdate`，并让滑块本地立即更新值（圆点跟手），拖动期间不被父组件回传值覆盖。
3. 新增 `test/custom_slider_test.dart`（点击换算 / 横向拖动 / 圆点跟手 3 例）。

---

## 四、备忘：连续滚动的既有机制（改这块前必读）

- `_pageHeights`：每页真实显示高度；未加载 → `_placeholderPageHeight`（视口高）。
- `_offsetForGp(gp)`：跳转偏移估算（**仅用于跳转，精度要求低**，落点靠
  `_currentPageFromViewport()` 校正）。
- `_currentPageFromViewport()`：页码来源 = 视口**起始端**（leading edge）可见 item
  的 index，不做像素累加反算（避免异步高度变化导致页码错位）。
- `_spliced`（`SplicedChapters`）：跨章拼接；prepend/append 各有 offset 补偿区。
- 高度突变（占位→真实）必须补偿滚动位置，否则视口内容被推走（`_prependZone` 机制）。
- 任何在滚动 listener 链路里可能同步执行的 `setState` 都要防「build 中 setState」
  （见 TESTING.md 第五节教训）。
