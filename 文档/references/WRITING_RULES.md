# 写作约定 / 代码规范 / 开发者偏好

> **适用场景**：写文档、提交代码、改 reader 代码时遵守。

## 1. 书源内容严禁写入 README.md

- **不管书源修没修过、维不维护，书源相关的内容（如书源修复、书源新增等）一律不准写进根目录 `README.md`**。
- README.md 只记录 App 本身的功能改动（阅读器、收藏、追更、UI 等），不记录任何书源层面的变化。
- 书源的改动记录应写在 `GIT_WORKFLOW.md`（如果跟 push/提交规则相关）或 `COMIC_SOURCE_DEV.md`（如果跟开发技巧相关）中。

## 2. reader_dbg.log 治理

- `_dbg` 日志入口**必须**加 `if (!kDebugMode) return;`（`kDebugMode` 来自 `package:flutter/foundation.dart`，release 构建 tree-shake 整分支）。
- **release APK 和 Windows release exe 永远不生成 `reader_dbg.log`**。debug 构建（`flutter run`）仍写，供本地测 bug。
- 日志写相对路径 `reader_dbg.log`，落 exe 工作目录 `build/windows/x64/runner/Release/`，不写 `C:/tmp`（不存在）。
- `reader_dbg.log` 在 `build/` 下，`.gitignore` 已忽略 → 它从未进过 git。用户说「删了再 push」时先 `git ls-files --error-unmatch` 确认未被跟踪。

## 3. 输出文件不带 BOM

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
