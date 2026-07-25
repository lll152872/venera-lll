# 本地构建 / 调试 必备事项（Venera 漫画阅读器）

> 本文件记录本地开发时必须遵守的约定，避免踩坑。新 agent 接手先读这个。
>
> Git 推送 / 提交规则 / 跳过 CI / Release 发布 → 见同目录 `GIT_WORKFLOW.md`
> 书源开发注意事项 → 见同目录 `COMIC_SOURCE_DEV.md`

## 1. 本地只能 build Windows exe，不能 build Android APK

- 本地环境只能出 `flutter build windows`（exe），**无法**出 APK。
- **根因**：Gradle daemon 崩溃（疑似内存不足，`-Xmx4G` 也崩）、NDK 27 license 缺失（`flutter_7zip` 插件要 `ndk;27.0.12077973`，本机只有 NDK 28）。**不要浪费时间重试本地构建**。
- 出 APK 只能走 **GitHub Actions 云构建**。
- 下载 APK → 见同目录 `GIT_WORKFLOW.md` 第 4 节。

## 2. Venera 版本号规则

- 版本号由用户（release 时）指定，**不要自己随意改**。
- 只有用户说「release」并给出两数字版本号时，才按规则修改。
- **格式铁律**：
  - 对外发布 / Release tag 只用两个数字（如 `v2.0`），不再用三数字 patch 位（如 v1.6.4）。
  - `pubspec.yaml` 内部 `version:` 字段写为 `x.y.0+build`（build 取整百，如 `2.0.0+200`）。
- **更新版本必须同时改两个地方**：
  - `pubspec.yaml` 的 `version:` → `x.y.0+build`
  - `lib/foundation/app.dart` 的 `final version` → `"x.y.0"`（不含 build 号）
  - 两者必须版本号一致，否则关于页面显示的是 app.dart 里的值。
- 平时开发提交不要动版本号，也不要动 `pubspec.lock`（本地 analyze 若改动需 `git checkout` 还原）。

## 3. 永不删 pubspec.lock / 永不 flutter clean / 不走中国镜像

**禁止操作**：
- ❌ 删 `pubspec.lock` —— 重新解析依赖会导致 FRB / transitive deps 全线漂移，不可逆
- ❌ `flutter clean` —— 等效破坏力，会删整个 `.dart_tool/` 目录（含 `package_config.json`）
- ❌ `flutter pub get` 走中国镜像（`PUB_HOSTED_URL=https://pub.flutter-io.cn`）

**为什么走中国镜像致命**：
- 环境变量 `PUB_HOSTED_URL` 和 `FLUTTER_STORAGE_BASE_URL` 当前全局默认指向中国镜像
- 经此跑 `flutter pub get`，Dart 会把 `package_config.json` 写到指向 `pub.flutter-io.cn` 的路径
- 更致命：中国镜像可能有新版 FRB（如 2.12.0），而 lockfile 锁的是 2.11.1
- 结果：`package_config.json` 指向镜像站的 `flutter_rust_bridge-2.12.0`，但 `rhttp` 用 FRB 2.11.1 codegen → 版本不匹配 → **所有网络请求全挂**

**安全操作**（仅删单文件 + 走 pub.dev 重建）：
```bash
rm .dart_tool/package_config.json
unset PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL
flutter pub get
```
然后 `build-win.bat` 重建。

**每次 `flutter analyze` / `flutter build` 后**：
- 它们会不经意改动 `pubspec.lock`（走中国镜像）。跑完后必须 `git checkout -- pubspec.lock` 还原。
- 提交规则见 `GIT_WORKFLOW.md` 第 2.2 节。

## 4. 报 "flutter rust bridge has not been initialized" 怎么修

**不要打补丁、不要加 fallback、不要猜**。按下面步骤查。

**症状**（从日志导出来看）：
```
DioException [unknown]: null
Error: Bad state: flutter rust bridge has not been initialized.
Did you forget to call await RustLib.init();?
```

**诊断**（每一步都要实际执行，不要跳过）：
1. 打开运行日志 `%APPDATA%/com.github.wgh136/venera/logs.txt`
2. 搜 `error init`，看版本不匹配的具体报错，例如：
   ```
   Bad state: rhttp's codegen version (2.11.1) should be the
   same as runtime version (2.12.0).
   ```
3. 检查 `package_config.json` 是否被中国镜像污染（**最高频根因**，2026-07 新发现）：
   ```bash
   grep "flutter_rust_bridge" .dart_tool/package_config.json
   ```
   如果输出 `pub.flutter-io.cn/flutter_rust_bridge-2.12.0`——确认**中镜像污染**。此时 lockfile 写死 2.11.1 但 package_config.json 指向镜像站的 2.12.0，版本脱节。

**修复**（两个步骤）：
1. 删 `.dart_tool/package_config.json` + 走 pub.dev 重新 `flutter pub get`（见第 3 条）
2. `build-win.bat` 重建 exe

**预防**：
- 任何 `flutter pub get` 之前必须 `unset PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL`
- 可以把 `PUB_HOSTED_URL` 和 `FLUTTER_STORAGE_BASE_URL` 从系统全局环境变量移除，只在需要走镜像时临时设置

## 5. CI analyze 失败诊断

- Venera CI 的 `analyze` 步骤 `fatal-warnings: true` —— **只要有 warning 级就判 failure**（info 级不致命，`fatal-infos: false`）。
- APK 构建步骤是独立的，analyze 挂 ≠ APK 挂。用户说「构建挂了」时先 `gh run list --limit 5` 区分是哪个 job。
- 查某次 run 为何失败：`gh run view <run_id> --log-failed`。看 `##[warning]` 行即我们的锅。
- **本地验证命令**（权威，不被 LSP 缓存骗）：
  ```bash
  flutter analyze 2>&1 | grep -E "warning -|error -" || echo "OK 无 warning 无 error"
  ```
  只看 warning/error 行；info 级（`deprecated_member_use`）不用管。
- 常见引入的 warning：unused_import（重构后残留的 import）、unused_element（死常量）、invalid_null_aware_operator（`late final` 上用 `?.`）。

## 6. reader_dbg.log 治理

- `_dbg` 日志入口**必须**加 `if (!kDebugMode) return;`（`kDebugMode` 来自 `package:flutter/foundation.dart`，release 构建 tree-shake 整分支）。
- **release APK 和 Windows release exe 永远不生成 `reader_dbg.log`**。debug 构建（`flutter run`）仍写，供本地测 bug。
- 日志写相对路径 `reader_dbg.log`，落 exe 工作目录 `build/windows/x64/runner/Release/`，不写 `C:/tmp`（不存在）。
- `reader_dbg.log` 在 `build/` 下，`.gitignore` 已忽略 → 它从未进过 git。用户说「删了再 push」时先 `git ls-files --error-unmatch` 确认未被跟踪。

## 7. 书源内容严禁写入 README.md

- **不管书源修没修过、维不维护，书源相关的内容（如书源修复、书源新增等）一律不准写进根目录 `README.md`**。
- README.md 只记录 App 本身的功能改动（阅读器、收藏、追更、UI 等），不记录任何书源层面的变化。
- 书源的改动记录应写在本文件（如果跟构建/调试相关）或 `COMIC_SOURCE_DEV.md`（如果跟开发技巧相关）中。

## 8. build-win.bat

- 批处理脚本的 `echo` / 提示 / 报错文字必须**全中文**，禁英文单词。
- 功能：含 frb 版本修复、sqlite3.dll 保护、数据备份还原。用 `cmd /c build-win.bat` 调用（git-bash 终端不能直接 `./build-win.bat`）。

## 9. 输出文件不带 BOM

所有输出文件（`.dart` `.js` `.md` `.txt` 等）UTF-8 无 BOM。

---

## 开发者偏好速查

- 改动选**最小最简单**方案，不要过度设计
- 给的数字**字面理解**，不二次猜测（如"15"就是 15，不要再推算是秒/分/张数）
- 写完先**本地测**再 push 触发 CI
- 网络走 **Steam++ 代理**才能 git push（见 `GIT_WORKFLOW.md` 第 1 节）
- 不要猜用户意思——**直接问**
- 改 reader 先加**一整套诊断日志**（宁多勿漏），让用户最多测两次
- 诊断 bug 时一次把所有可疑日志加齐，不要改一步算一步
