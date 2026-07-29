# 重构：页码算法从像素累加反算改为 item 实际位置

## 背景
git 历史中铁证：`_pageHeights` + `_gpFromPixels`（像素累加反算页码）机制导致了 **6 次** A 类 bug（#2,#12,#13,#16,#17,#18），反复修反复出。补丁路线已死，必须换机制。

## 方案
保留自有 `ScrollController` + `ListView`（解决回退），保留 `SplicedChapters`（无缝跨章），但**页码算法从"像素累加反算"改为"item 实际渲染位置"**。

### 核心改动
1. **新增** `_currentPageFromViewport()`：遍历可见 item 的 `RenderBox.localToGlobal` 位置，找视口中心对应的 item index → 这就是页码（gp）
2. **新增** `_ItemContextRegistrar` widget：item build 时注册 context，dispose 时注销
3. **修改** `_syncReaderState`：用 `_currentPageFromViewport()` 替代 `_gpFromPixels(pixels)`
4. **删除** `_gpFromPixels`
5. **删除** `_compensatePixelsForFrontRemoval`（不再需要补偿 pixels）
6. **简化** `onImageLoaded`：只更新 `_pageHeights`（跳转估算用），删除 A 补偿
7. **删除** B1 预测量（`_buildSplicedItem` 里的 `cachedSizeFor` + `ImageSizeCache.get` 逻辑）
8. **修改** 两处 `unloadExcess`：删除 `_compensatePixelsForFrontRemoval` 调用

### 保留
- `_pageHeights` + `_offsetForGp`：降级为跳转估算（精度要求低，不准只影响跳转位置，不影响页码）
- `_computeAxisSize`：onImageLoaded 更新 `_pageHeights` 用
- `SplicedChapters`：多章拼接不变
- `ComicImage`：item 高度由它自己决定（零黑边不变）
- `ImageSizeCache`：B2 持久化缓存保留
- 常驻 Stack：跨章重载已解决，不动
- `_resetSplicedState` 的 `_pageHeights.clear()`

### 不改
- 水平模式支持：`_currentPageFromViewport` 根据 `reader.mode` 用 x 或 y 坐标

## 解决的 bug（9/15 历史根因）
- A 类×6（_pageHeights 不同步）：页码不再依赖 _pageHeights，根因消除
- B 类×2（双轨不一致）：页码由 item 位置决定，双轨不一致只影响跳转精度
- D 类×1（回退）：_currentPageFromViewport 返回全局 gp，不会回退

## 不影响的已修复 bug
- C 类×4（跨章重载）：常驻 Stack 已解决，不动
- E 类×1（渲染对齐）：item 高度由 ComicImage 决定，和页码算法无关
- F 类×1（触发逻辑）：已修

## 跳转精度
`toPage(n)` 用 `_offsetForGp(n)` 估算像素跳转：
- B2 缓存命中或图片已加载：`_pageHeights` 准确，跳转精确
- 图片未加载且 B2 未命中：用占位估算，跳到附近，跳转后 `_syncReaderState` 自动校正页码

## 风险
- `localToGlobal` 性能：可见 item 3-5 个，遍历成本可忽略
- item context 生命周期：`_ItemContextRegistrar` 的 dispose 保证清理
- 首帧（item 未 build）：fallback 到 `reader.page`
