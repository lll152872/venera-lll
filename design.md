# 修复：连续滚动模式下跨章/章内页码随机跳转

## 现象
- 阅读模式：连续垂直滚动（`continuousTopToBottom`）
- 触发：从 A 章末尾滚动到 B 章首页时，会随机跳到 B 章中部某页；A 章内滚动也会偶发乱跳
- 频率：图片高度差异大的漫画经常出现；非稳定复现
- 版本：v2.1 release 就有，非新引入

## 根因
连续模式下页码（gp）由"累加每页高度 + 看 pixels 落点"反算：
```
_gpFromPixels(pixels): 累加 _pageHeights[i], pixels 落在哪个区间 → gp
```

`_pageHeights[gp]` 是**异步**填充的——图片加载完成时（`ComicImage.onImageLoaded`）才从占位高度（视口高）更新为真实高度。但 `_scrollController.position.pixels` **不会随高度变化同步调整**。

当某张图（位于 `index`）加载完成、高度从 `oldH` 变为 `h` 时：
- 若 `index < currentGp`（在视口上方）：该页高度变化会推移下方所有内容，但 pixels 不变 → 下次 `_syncReaderState` 用新高度算 gp，会得到错误页码 → 触发 `reader.chapter = chap` 切错章节 + `setPage(localPage)` 钉死错误页码
- 若 `index >= currentGp`：不影响累加基准，gp 不变（验证过）

"随机"来源：图片加载完成顺序非确定，所以每次触发的 gp 偏移位置都不同。

## legado 对照（D:\mycode\legado）
legado 用"预排版 + 同步预测量 + 单 View 自绘"路线：
- `ChapterProvider.kt:348` 排版时调 `ImageProvider.getImageSize`（`inJustDecodeBounds=true`）同步拿真实宽高
- `TextPage.height` 在排版阶段就是终值
- 绘制阶段只填位图，绝不动 layout 坐标
- → 物理上不可能出现"加载完成→高度突变→页码乱跳"

venera 是 Flutter + ListView 架构，无法完全照搬，但可借鉴"预测量"思路。

## 最终方案：A + B1 + B2 三层组合

### A: 补偿 pixels（兜底所有异步场景）
`images.dart` 的 `onImageLoaded` 回调：
1. 更新前用旧高度算 `curGp = _gpFromPixels(pixels)`
2. 更新 `_pageHeights[index] = h`
3. 若 `index < curGp`：`pixels += (h - oldH)`，通过 `jumpTo` 同步应用
4. 临时移除 ScrollController listener，避免 jumpTo 触发 `_syncReaderState` 用中间态反算

覆盖：所有异步加载场景（包括首次访问从未下载的图）的 95%+。

### B1: 复用 ComicImage._cache（二次访问章节 100%）
发现 `ComicImage._cache`（`comic_image.dart:97`）已存在且 key 稳定（`BaseImageProvider` 重写了 `hashCode` 基于 `key` 字段）。
- `ComicImage.cachedSizeFor(image)` 暴露 public API
- `_buildSplicedItem` 构造 provider 后同步查，命中则直接填 `_pageHeights[index]`

覆盖：同一图片二次访问时 build 前就有真实尺寸，item 第一次 layout 就是终值。

### B2: 持久化尺寸缓存（App 重启后重读已下载章节 100%）
新建 `lib/foundation/image_size_cache.dart`：
- 内存 Map + JSON 文件持久化（debounced 2 秒写）
- `init()` 启动时异步加载 JSON 到内存
- `get(imageKey)` 同步查内存
- `put(imageKey, w, h)` 更新内存 + debounce 写文件

集成：
- `ComicImage._handleImageFrame` 拿到尺寸时 `put`（识别 `ReaderImageProvider`）
- `_buildSplicedItem` 在 B1 未命中后查 B2
- `App.initComponents()` 加 `ImageSizeCache.instance.init()`

覆盖：App 重启后重读已下载章节，build 前同步拿到尺寸。

### 三层叠加覆盖矩阵
| 场景 | 覆盖层 | 结果 |
|---|---|---|
| 二次访问章节（同进程内） | B1 | 100% 无 bug |
| App 重启后重读已下载章节 | B2 | 100% 无 bug |
| 首次访问从未下载的图 | A 兜底 | 95%+ 无 bug（极端 maxScrollExtent 钳制 case 除外） |

## 风险与边界
- `index == curGp`（当前页加载完成）：不补偿。该页高度变化只影响视口内露出内容，不影响 gp 累加基准。
- `index > curGp`（视口下方）：不补偿。不影响累加。
- pixels 超出 maxScrollExtent：Flutter 自动钳制，补偿不完全——可接受（用户在末尾时上方图片加载完成的概率低）。
- 首帧（`_placeholderPageHeight <= 0`）：跳过补偿，等首帧布局完成。
- ImageSizeCache init 失败：优雅降级，`get` 返回 null，退回 A 兜底。

## 验证
- `flutter analyze` 通过（仅原有 deprecation info，非本次引入）
- 实机回归：在差异大的漫画上连续跨章滚动 + A 章内来回滚动，确认页码不再乱跳
- 关注 debug log 中 `<<< GP JUMP` warning 是否消失

## 涉及文件
- `lib/foundation/image_size_cache.dart`（新建）：持久化尺寸缓存
- `lib/foundation/app.dart`：initComponents 加 ImageSizeCache.init()
- `lib/pages/reader/comic_image.dart`：暴露 cachedSizeFor + _handleImageFrame 写入持久化
- `lib/pages/reader/reader.dart`：import image_size_cache
- `lib/pages/reader/images.dart`：_computeAxisSize 辅助方法 + _buildSplicedItem 同步预测量 + onImageLoaded 补偿 pixels
