# Git 推送 / Release 工作流（Venera 漫画阅读器）

> **适用场景**：git push / 提交规则 / CI 跳过与触发 / Release 发版。
> 构建 / 版本号 / 调试环境问题 → `BUILD_WINDOWS.md` / `VERSION_RULES.md`；书源开发 → `COMIC_SOURCE_DEV.md`。
> 导航入口见 `../0_必看.md`。

## 1. 推送 git（走 Steam++ 代理，需跳过 SSL 证书验证）

- 本机网络走 Steam++ 代理才能 git push。经代理后 Git 的 CA bundle 缺 GitHub 服务器证书链，`git push origin master` 会报：
  `SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)`
- 解决（仅本次 push 进程内临时关闭，**不写进 git config 或任何文件**）：
  ```bash
  export GIT_SSL_NO_VERIFY=1 && git push origin master
  ```
- `origin-ssh` (git@github.com) 的 22 端口被拒，不可用，只用 https origin。

## 2. 提交规则：什么可以 push，什么不可以

### 2.1 书源 JS 文件不要 push

- `book source/*.js`（如 baozi.js / jm.js / new.js）是本地书源，**不要** add/commit/push 进主仓库。
- 原因：书源是用户本地私有的，不属于公共仓库内容；且 push 会不必要地触发 CI（即使可用 `[skip ci]` 跳过，也不应进仓库）。
- 处理：保持它们 untracked / 不纳入提交。提交时只 `git add` 真正的源码改动（如 `lib/pages/reader/*.dart`），不要 `git add .`。

### 2.2 pubspec.lock 不要进 commit

- 每次 `flutter analyze` / `flutter build` 后会不经意改动 `pubspec.lock`。跑完后必须还原：
  ```bash
  git checkout -- pubspec.lock
  ```
- 提交时绝不把 `pubspec.lock` 带进 commit。

### 2.3 其他 .gitignore 违规文件

以下文件**决不能进 git**（已在 `.gitignore` 中）：
- `testlog/` —— 本地测试日志
- `windows/sqlite3-src/` —— sqlite3 源码 25 万行，误提交后 GitHub 语言统计 C 占大头
- `apk-output/` —— CI 构建下载的本地 APK
- `android/build/` —— Android 构建缓存
- `build_output/` —— 构建输出
- `ci_log.txt` —— CI 日志
- `pubspec.lock.bak` —— lock 备份

若误提交：`git rm --cached -r <路径>` + `git push --force` 才能清掉。

## 3. 跳过 CI 构建 vs 触发 CI 构建

### 3.1 跳过 CI（push 不触发构建）

commit 消息中包含以下任一关键词，push 不会触发 CI：

```
[skip ci]
[ci skip]
[no ci]
```

示例：
```bash
git commit -m "docs: 只改文档不触发构建 [skip ci]" && git push
```

### 3.2 普通 push（触发构建，不出 Release）

正常 `git push origin master`，触发 `Build Android APK` workflow，产物为 artifact，不自动建 Release。

适用于日常开发 / bug fix 提交。

### 3.3 发版 push（触发构建 + 自动创建 Release）

推 `v*` 格式的 tag 会触发 `Build Android APK` → 自动创建 GitHub Release 并挂上 APK。

**完整发版步骤**：

1. 改版本号（两处，见 `VERSION_RULES.md`，自 v2.4.1 起统一三位）：
   - `pubspec.yaml` 的 `version:` → `x.y.z+build`
   - `lib/foundation/app.dart` 的 `final version` → `"x.y.z"`
2. 提交并推送：
   ```bash
   git add pubspec.yaml lib/foundation/app.dart
   git commit -m "chore: 版本号升至 vX.Y.Z"
   git push origin master
   ```
3. 打 tag 并推送：
   ```bash
   git tag -a vX.Y.Z -m "Venera vX.Y.Z"
   git push origin vX.Y.Z
   ```
4. CI 自动构建 + 自动建 Release（约 15-20 分钟），不需要手动操作。
5. 验证：`gh release view vX.Y.Z` 应列出 APK 附件。

### 3.4 用现有 APK 直接挂 Release（不改 pubspec）

若用户说「下载当前 APK 作为 vX.Y.Z 发布」且未提改 pubspec：直接用现有 APK 挂 release tag。

代价是 APK 内部 pubspec version 滞后于 tag。下次正式发版前务必补升版本号再 push 构建。

## 4. 下载 CI 构建的 APK（手动）

正常情况下发版走 3.3 自动流程，不需要手动下载。但如果需要手动取 artifact：

```bash
gh run list --workflow "Build Android APK" --limit 1 --json databaseId
# 记下 run id，等状态 completed
gh run download <run_id> -D /path/to/output
# APK 路径：/path/to/output/venera-apk/app-release.apk
```

**坑**：`gh run list --limit 1` 拿的是 analyze run（无 artifact），**必须用 `--workflow "Build Android APK"` 筛选**才下得到 APK。

如果 run 已过期或失败：`git commit --allow-empty -m "rebuild" && git push` 重新触发。

## 5. 更新已发布的 Release

如果要替换已有的 release（如修了版本号 bug）：

```bash
# 1. 删除旧 release
gh release delete vX.Y.Z --yes

# 2. 删除旧 tag 并重建
git tag -d vX.Y.Z
git tag -a vX.Y.Z -m "Venera vX.Y.Z"
git push origin :refs/tags/vX.Y.Z
git push origin vX.Y.Z

# 3. CI 自动重建 Release（等 15-20 分钟）
```
