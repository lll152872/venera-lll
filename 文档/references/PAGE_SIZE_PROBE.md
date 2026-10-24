# 连续滚动：跳转落点精度方案（读文件头拿真实页高）

> **状态**：方案已定，**2026-10-25 开工**。
> 起因：用户报「点进度条后内容跳了但页码/滑块不动」。页码那半已修（见文末「已修部分」），
> 剩下的「落点不准」是独立问题，本文档记录根因、数据和实施方案。
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

## 二、方案 A：读图片文件头拿真实宽高（推荐，已定）

### 2.1 思路

宽高就写在图片**文件头**里，只读前 64KB 就能解析，**不需要解码整图**：

| 格式 | 头信息位置 |
|---|---|
| WebP | `RIFF....WEBP` + `VP8X`（24-29 字节，宽高各 24bit LE）/ `VP8L`（bit 布局）/ `VP8 `（帧头） |
| JPEG | 扫描 `SOF0/1/2/...` 段，取 `height(2B) width(2B)` |
| PNG | `IHDR` 段，宽高各 4B BE |
| GIF | 逻辑屏宽高各 2B LE |

- **本地已下载的章**：直接读本地文件 → **零网络、零解码**。
- **网络章**：发 `Range: bytes=0-65535` 请求 → 每页一个小请求
  （20 页约 1.3MB，比加载 20 张整图小一个数量级）。
- 探测结果写回现有 `ImageSizeCache` → `_resetSplicedState()` 会自动把缓存里的真实高
  回填进 `_pageHeights` → **跳转偏移自动变准，代码结构不用改**。

### 2.2 接入点（现成的，不用重构）

| 位置 | 作用 |
|---|---|
| `lib/foundation/image_size_cache.dart` | `get(imageKey)` / `put(imageKey, size)`，key = URL 或 `file://` 路径；`put` 已带 debounce 写 JSON |
| `lib/pages/reader/images.dart` `_resetSplicedState()` | 章节加载时用 `ImageSizeCache` 回填 `_pageHeights`（**探测结果写进缓存，这里自动生效**） |
| `lib/pages/reader/images.dart` `_computeAxisSize()` | 像素尺寸 → 显示高度 |

### 2.3 待建模块

`lib/foundation/image_size_probe.dart`：

```
Future<Size?> probeImageSize(String imageKey)
  ├─ file:// → dart:io 读前 64KB → 解析头
  ├─ http(s) → Dio Range 请求（ResponseType.stream，读够就 cancel）→ 解析头
  └─ 失败/不支持 Range → 返回 null（回退占位高，不崩）
```

调度：章节图片列表拿到后，**后台**低并发探测本章所有页（并发 3~4，
与 `ContinuousModeState._kMaxConcurrentDownloads` 一致）→ `ImageSizeCache.put`。
**不在跳转路径上同步等待**，UI 不卡。

### 2.4 验收标准

1. 单测：WebP / JPEG / PNG 头解析各一例（含损坏数据返回 null）。
2. 跳转精度测试：模拟 50 页、只有前 10 页尺寸已知 → 跳到第 30 页
   → 断言视口顶部 item == 第 30 页（不再偏 1~13 页）。
3. 回归：`test/reader_continuous_scroll_test.dart`（已知 2 个基线红用例除外，见 TESTING.md 第六节）
   + `test/custom_slider_test.dart` 全绿。
4. `flutter analyze` 0 warning（CI `fatal-warnings: true`）。

### 2.5 风险与回退

| 风险 | 处理 |
|---|---|
| 服务器不支持 Range | 探测返回 null → 回退占位高（= 现状），不崩、不阻塞 |
| 每章几十个小请求 | 后台低并发 + 只探测未缓存的页；探测失败不重试 |
| 探测请求拖慢开章 | 不阻塞 UI：先按占位高渲染，尺寸到了自动回填 → 页高修正后视口会微调 |
| `ImageSizeCache` 写入竞争 | 复用现有 `put`（已 debounce 落盘） |

---

## 三、已修部分（2026-10-24，本次已 push）

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
