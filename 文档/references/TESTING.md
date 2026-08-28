# Venera 测试（TESTING.md）

> 连续滚动模式的两套自动化测试：真实数据 E2E（integration_test）+ 确定性 widget 测试（test）。
> 适用：改阅读器代码（lib/pages/reader/**）后验证连续滚动/跨章/prepend 没坏。

---

## 一、E2E 集成测试（integration_test/reader_e2e_test.dart）

### 1.1 是什么

- **真实链路 E2E**：程序生成 32 章本地漫画（每章 50-60 页随机、随机位置插 1 页"休刊"章、每页不同尺寸、图上标注 `chXX pYY`），真实文件 I/O、真实图片解码、真实 drag 手势驱动真实 `ContinuousMode` + `SplicedChapters`。
- 全量 1697 张 PNG 首次生成约 31 秒，幂等（目录存在即跳过）。
- 3 个用例：
  1. **滚动翻页页码正确**——drag 驱动，页码前进不回退
  2. **滚过章末跨章拼接不跳变**——循环 drag 过 ch1 末页，断言进入 ch2、offset 不回退
  3. **从休刊 ch9 向上滚到 ch1 再向下滚到底**——向上无缝 prepend 回滚 8 章到 ch1，再向下无缝 append 到 ch32 末页；**含轨迹断言**（向下阶段每步 gp 不回退超 2 页，见 §三）

### 1.2 怎么跑（必须在用户终端跑）

**为什么 agent 不能代跑**：下面命令全是 PowerShell 语法（`$env:PATH` 等，§1.3 的 junction 同理），agent 环境只能用 bash、**没有 pwsh**，执行不了这些步骤；且 agent 在 bash 后台跑 flutter 一旦卡住被强杀，会触发 §四 的 lockfile 死锁。所以 E2E 一律由用户在自己的终端执行。

```powershell
cd D:\mycode\venera
$env:PATH = "D:\edge;D:\flutter_3.44.0\bin;$env:PATH"
flutter test integration_test/reader_e2e_test.dart -d windows --no-pub
```

- 小规模快速验证（4 章）：加 `--dart-define=E2E_SMALL=true`
- 首次 build 约 1 分钟，全量测试约 5 分钟

### 1.3 一次性环境前提

E2E 依赖 `build/windows/x64/runner/Debug/` 的完整产物（flutter_tools 桌面 integration_test 的 bundle 有 bug，不自动 copy）：

1. **plugin dll**：从 `build/windows/x64/plugins/*/Debug/` + `shared/Debug/` copy 到 `runner/Debug/`（20+ 个）
2. **flutter_windows.dll + icudtl.dat**：从 `D:\flutter_3.44.0\bin\cache\artifacts\engine\windows-x64/` copy
3. **kernel 注入**：flutter_tools 把测试 kernel 装到 `runner/Release/data/` 但 exe 是 Debug——建 junction 一劳永逸：
   ```powershell
   Remove-Item 'D:\mycode\venera\build\windows\x64\runner\Debug\data' -Recurse -Force
   New-Item -ItemType Junction -Path 'D:\mycode\venera\build\windows\x64\runner\Debug\data' -Target 'D:\mycode\venera\build\windows\x64\runner\Release\data'
   ```

### 1.3.1 cargokit build 挂起（`Could not find item ... AppData`）

**症状**：`flutter test -d windows`（或任何触发 Windows build 的命令）卡在 `Building Windows application...` 十分钟无产物，cmake/MSBuild 进程存活但 CPU 时间 0 秒。日志尾部有 `Get-Item : Could not find item C:\Users\<user>\AppData`（出自 `windows/flutter/ephemeral/.plugin_symlinks/rhttp/cargokit/cmake/resolve_symlinks.ps1:25`）。

**根因**：cargokit 的 `resolve_symlinks.ps1` 逐段 `Get-Item` 解析 symlink 路径，**AppData 是隐藏目录**，Windows PowerShell 5.1 不加 `-Force` 对隐藏项报 "Could not find item"，cmake configure 随之挂死。已修复：该脚本 `Get-Item $realPath` 已加 `-Force`（注释在行内）。

**注意**：`.plugin_symlinks` 是 ephemeral 生成物，若日后 `flutter pub get`/IDE 重新生成把它覆盖回去（-Force 丢失），按上述一行补丁重打即可。

### 1.4 测试代码关键决策（改测试前先看）

- **mini-init**（setUpAll）：`App.init → JsEngine().init() → ComicSourceManager().init() → App.initComponents → AppTranslation.init`。**顺序必须这样**——`LocalManager.init` 里 `await ComicSourceManager().ensureInit()`，而 `ComicSourceManager.doInit` 里 `await JsEngine().ensureInit()`，ensureInit 只在对应 `init()` 调用后才 complete，缺了永久挂起（实测卡 12 分钟）。
- **不调 `Rhttp.init()`**：本机 frb 版本脱节（codegen 2.11.1 vs runtime 2.13.0，镜像污染，见 0_必看 §四），sanity check 直接抛。测试全走本地文件，无需网络。
- **等待用 `tester.runAsync(() => Future.delayed(...))`**（_waitReal）：`pumpAndSettle` 对真实图片解码永不 settle（跨章拼接持续产生帧，卡 5 分钟超时）；裸 `pump` 不推真实异步。
- **翻页用 `tester.drag` 真实手势**：`ContinuousModeState.animateToPage` 的 Future 在 integration_test 下不可靠（ticker 不走）。
- **页码文本是 `"章节名 : 页码/总页"` 格式**（scaffold.dart，章节名>8 字符截断），断言用 `find.textContaining('1/55')` 而非精确匹配。
- **`testCurrentPage` 是全局拼接页码**（spliced 内 index），页码文本是章内语义——断言要分清。
- **切章只在滚动 listener 触发时发生**：跨章后需再滚一次让 `reader.chapter` 切换（循环 drag 并等页码文本变 `x/n2` 格式）。

---

## 二、Widget 测试（test/reader_continuous_scroll_test.dart）

### 2.1 是什么

- 确定性 widget 测试（无真实 I/O）：`_FakeReader`（ReaderView 假实现）+ `_GatedImageProvider`（Completer 门控图片加载，模拟"滚动中图片完成加载"的竞态）。
- 8 个用例：图片收缩不回滚（核心回归）、prepend 触发/补偿/映射/zone、chapter1 终止、append 共存、既有滚动回归。
- **测试驱动技巧**：`_jumpToOffset` 需"jumpTo → pump → jumpTo(+0.5)"两步（jumpTo 单次触发 listener 跑在旧布局）；章节用 20 页（≤10 页会让 gp=1 同时触发 append+prepend 竞争）。

### 2.2 怎么跑

```powershell
cd D:\mycode\venera
$env:PATH = "D:\edge;D:\flutter_3.44.0\bin;$env:PATH"
flutter test test/reader_continuous_scroll_test.dart --no-pub
```

---

## 三、断言盲区补强（轨迹记录器）

现有测试曾全是"最终状态断言"，会漏 3 类回跳：

- **盲区 A**：瞬态回跳（中间帧"跳回又拉回"，最终 offset 对）
- **盲区 B**：gp 对但 (ch,p) 映射错（offset 平移错位）
- **盲区 C**：上下交错滚动 / 动画中间帧

已落地两处：

1. **Widget 测试①**（test/reader_continuous_scroll_test.dart）：`_trackPoint()`（取 `testSpliced.chapterOfPage(gp)` 的 (ch,p)）+ `_parseTrack()`，图片收缩（gCompleter.complete）后连 pump 5 帧断言 ch 不回退、gp 不回跳超 2 页。
2. **E2E 测试③**（integration_test/reader_e2e_test.dart ch9 场景）：`record()` 每步 drag 记录 `(gp, ch, p)` 轨迹；**向下阶段严格断言 gp 不回退超 2 页**（append 不改变当前 gp、向下阶段无 prepend，回退 >2 只可能是瞬态回跳——图片收缩补偿失效或页码反算错误）；向上阶段 prepend 会平移 gp（内容没动），单调断言不适用，只记录观察（最后 debugPrint 轨迹）。

**盲区 C 部分覆盖**（上下交错滚动已在 E2E 测试③覆盖；`animateToPage` 中间帧仍可复用 `_trackPoint` 扩展）。

---

## 四、环境坑与恢复

### lockfile 死锁（最高频）

**症状**：`D:\flutter_3.44.0\bin\cache\lockfile` 被锁（可读不可写/删除 ACCESS_DENIED），flutter 任何命令卡死无输出。

**根因**：强杀 flutter test 进程（TaskStop / taskkill）后句柄残留。**agent（只能 bash、无 pwsh）后台跑 flutter + 强杀 = 必现**；用户终端跑正常。

**恢复**（用户给的流程）：
```powershell
# 1) 查残留进程（无则跳过）
tasklist | findstr /i "dart flutter venera"
taskkill /F /IM dart.exe

# 2) 删锁（用系统版 Python，托管版 ctypes 段错误）
C:\Users\DELL\AppData\Local\Programs\Python\Python312\python.exe D:\mycode\venera\fix_flutter_lock.py
```
`fix_flutter_lock.py` 循环重试 DeleteFileW；若一直 err=5，是 delete-pending 内核残留，等 20-60 分钟或重启电脑。

### ephemeral 目录破坏

**症状**：build 报 `C1083: 无法打开源文件 cpp_client_wrapper/*.cc`。

**根因**：强杀 flutter 进程中断 ephemeral 生成。

**恢复**：删 `windows/flutter/ephemeral`（生成目录，flutter 会重新生成）：
```powershell
Remove-Item D:\mycode\venera\windows\flutter\ephemeral -Recurse -Force
```

---

## 五、测试暴露并修复过的 bug（lib）

1. **本地漫画连续滚动跨章 null 崩溃**：`_prefetchChapter`/`_appendNextChapter` 直接 `comicSource!`（local 为 null）——抽 `_fetchChapterPages`，local 走 `LocalManager().getImages`。
2. **`reader_image.dart` file:// 未 strip**：`File(imageKey)` 不认 URI——改 `substring(7)`。
3. **setState during build ×3**（滚动 listener 链路，prepend/append 时 build 中触发）：
   - `_updateReaderStateForSpliced` 的 `scaffold.update()` → postFrame 延迟
   - `_prependPrevChapter` 的 setState → build 阶段延迟 postFrame（doSplice 模式）
   - `_appendNextChapter` 的 setState → 同上；**否则 `markAppending(false)` 不执行，appendingNext 永久卡 true，向下拼接中途停止**（实测停在 ch27）
   - **教训：所有在滚动 listener 链路里可能同步执行的 setState 都要加 `schedulerPhase==persistentCallbacks` 保护**。
