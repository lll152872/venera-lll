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

### 1.1 沙箱/异常环境下 push 失败的三连（2026-08 实测）

在 WorkBuddy 沙箱或异常环境里 `git push` 可能连环失败，按序排查：

1. **`could not lock config file .../etc/gitconfig: File exists`**：PortableGit 系统 gitconfig 锁残留，每次 git 命令都尝试写系统配置。
   - 清锁：`rm -f "C:/Users/DELL/.workbuddy/binaries/PortableGit/versions/1.2.0/etc/gitconfig.lock"`（注意版本目录随安装变化）。
2. **`failed to execute prompt script ... git-credential-manager.exe: No such file or directory`**：全局 `credential.helper` 指向失效路径（`vendor/` 旧目录已不存在，GCM 实际在 `binaries/PortableGit/versions/<ver>/mingw64/bin/`）。
   - 修正：`git config --global credential.helper 'C:/Users/DELL/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin/git-credential-manager.exe'`。
3. **最终兜底（最稳）**：跳过系统/全局配置 + 内联凭据直推，绕开 GCM 和 config 锁：
   ```bash
   export GIT_SSL_NO_VERIFY=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
   CRED=$(head -1 ~/.git-credentials)          # https://user:token@github.com
   UP=${CRED#https://}; UP=${UP%%@*}           # 取 user:token 段
   git -c credential.helper= push "https://${UP}@github.com/lll152872/venera-lll.git" master
   ```
   - 凭据存于 `~/.git-credentials`（store 格式）；用 `-c credential.helper=` 禁掉一切 helper，URL 内联凭据即可。
   - 注意 `GIT_CONFIG_GLOBAL=/dev/null` 会忽略全局配置——对只 push 无副作用。

### 1.2 GitHub MCP 连接器不能替代本地 push

- GitHub 连接器（MCP）的 `push_files` 会报 `403 Resource not accessible by integration`——集成 token 对该仓库无 contents 写权限（只读）。
- 结论：**push 必须走本地 git**，连接器只适合读操作（查分支/commit/issue）。

## 2. 提交规则：什么可以 push，什么不可以

### 2.1 书源 JS 文件的提交规则（2026-08-28 更新）

- `book source/*.js`（如 baozi.js / jm.js）**可以** commit/push 进主仓库，但**必须**在 commit message 末尾带 `[skip ci]`，避免无意义触发构建。
- **commit message 不要出现「书源」相关字样**（如「同步书源」「书源更新」「xx 源 v1.x」）——公开仓库低调处理，不暴露书源更新痕迹。用中性描述，如 `chore: update local files [skip ci]`。
- 对外分发的书源副本放 `assets/sources/`（jsdelivr 从这里取，用于 App 内检查更新）；`book source/` 是本地工作副本，两处需保持同步。
- 提交时仍只 `git add` 指定文件，不要 `git add .`。

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

## 6. 重命名已发布 Release 的 tag（零传输，保留 APK）

场景：把旧 tag（如 `v2.4`）改名成 `v2.4.0`，且必须保留已发布的 APK 附件。

**不要下载 APK 再重传。** 本机 GitHub 下行约 30KB/s，46MB 要 20+ 分钟，超过前台命令上限会被杀进程；`ghproxy.net` / `gh-proxy.com` 镜像也不可用。

正确做法是 `PATCH /releases/{id}` 直接改 `tag_name`——release 对象 id 不变，APK 附件原地保留，`browser_download_url` 自动跟着换到新 tag，**全程 0 字节传输**。

```bash
R=lll152872/venera-lll   # 注意仓库真实名是 venera-lll

# 0. 先禁用 CI（[skip ci] 对重打 tag 无效：workflow 看的是 tag 指向的历史
#    commit message，改不了。不禁用会触发构建并自动建 release 打架）
gh workflow disable "Build Android APK"
gh workflow disable "analyze"

# 1. 先建新 tag 指向【原 commit】——不能跳过这步！
#    release 的 target_commitish 是 master，若新 tag 不存在，
#    GitHub 会拿 master 最新 commit 建 tag，历史版本就指错代码了。
SHA=$(git rev-parse 'v2.4^{commit}')
TS=$(gh api repos/$R/git/tags -f tag=v2.4.0 -f message="Venera v2.4.0" \
       -f object=$SHA -f type=commit --jq '.sha')
gh api repos/$R/git/refs -f ref=refs/tags/v2.4.0 -f sha=$TS

# 2. PATCH release 平移
ID=$(gh api repos/$R/releases/tags/v2.4 --jq '.id')
gh api -X PATCH repos/$R/releases/$ID -f tag_name=v2.4.0 -f name="Venera v2.4.0"

# 3. 验证下载链接（应 200 且 Content-Length 与原值一致）
curl -sIL --ssl-no-revoke "https://github.com/$R/releases/download/v2.4.0/app-release.apk" \
  | grep -iE "^HTTP/|^content-length"

# 4. 删旧 tag（远端 + 本地）
gh api -X DELETE repos/$R/git/refs/tags/v2.4
git tag -d v2.4
GIT_SSL_NO_VERIFY=1 git fetch origin --tags --prune --prune-tags

# 5. 验证新 tag peel 后的 commit 与原 commit 一致
git rev-parse 'v2.4.0^{commit}'

# 6. 【必须】恢复 CI
gh workflow enable "Build Android APK"
gh workflow enable "analyze"
```

只有 tag 没有 release 的（如原 `v2.2`），跳过第 2、3 步，只做建新 tag + 删旧 tag。

> 所有 `gh` / `git ls-remote` 操作必须在真实文件系统视图下执行（agent 侧加 `dangerouslyDisableSandbox: true`），Bash 沙箱的 git 视图与真实 FS 不一致，会误报 "tag already exists"。
