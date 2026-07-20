# 本地构建 / 推送 必备事项（Venera 漫画阅读器）

> 本文件记录本地开发时必须遵守的约定，避免踩坑。新 agent 接手先读这个。

## 1. 本地只能 build Windows exe，不能 build Android APK
- 本地环境只能出 `flutter build windows`（exe），**无法**出 APK。
- 出 APK 只能走 **GitHub Actions 云构建**：`git push origin master` 自动触发两个 workflow：
  - `analyze`（先跑完，无 artifact）
  - `Build Android APK`（慢，约 15-20 分钟，跑完上传 APK artifact）
- 下载 APK：`gh run download <Build_Android_APK_run_id> -D /tmp/venera-apk-fix`
  - APK 路径：`/tmp/venera-apk-fix/venera-apk/app-release.apk`
- 注意坑：`gh run list --limit 1` 拿到的是 analyze run（无 artifact），**必须指定 Build Android APK 的 run id** 才下得到 APK。
- 如果 run 已过期或失败：`git commit --allow-empty -m "rebuild" && git push` 重新触发。

## 2. 推送 git 必须取消 SSL 证书验证
- 本地 Git 的 CA bundle 缺 GitHub 服务器证书链，`git push origin master` 会报：
  `SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)`
- 解决：仅本次 push 进程内临时关闭验证（**不要写进 git config 或任何文件**）：
  ```powershell
  $env:GIT_SSL_NO_VERIFY='1'; git push origin master
  ```
- `origin-ssh` (git@github.com) 的 22 端口被拒，不可用，只用 https origin。

## 3. 改书源（.js 文件）不要 push 到主仓库触发 CI
- `book source/*.js`（如 baozi.js / jm.js / new.js）是本地书源，**不要** add/commit/push 进主仓库。
- 这些文件改动会不必要地触发 CI build APK，且不应进主仓库。
- 处理：保持它们 untracked / 不纳入提交；或 `.gitignore` 忽略（若尚未忽略）。
- 提交时只 `git add` 真正的源码改动（如 `lib/pages/reader/*.dart`），不要 `git add .`。

## 4. Venera 版本号规则
- 版本号由用户（release 时）指定，**不要自己随意改**。
- 只有用户说「release」并给出版本号时，才按该版本号修改对应版本文件（如 `pubspec.yaml` 的 `version:` 字段）。
- 平时开发提交不要动版本号。
- 也不要动 `pubspec.lock`（本地 analyze 若改动需 `git checkout` 还原）。

---
### 连续模式零黑边（legado 式）约定补充
- 每页 item 高度 = 图片真实显示高（ComicImage 内部按 cell 实际宽算），**不要写死屏高**。
- 页间距 = 0（对齐 legado 原版，图片首尾相接），`kPageSpacing` 保持 0.0。
- gp（页码）↔ 像素偏移用 `_offsetForGp` / `_gpFromPixels` 累加每页真实高度，不依赖固定 itemSize。
- `_pageHeights` 用 spliced list 的 index 作 key；prepend/unloadExcess 改变 index 后必须平移该 map。
- 跨章无缝核心（SplicedChapters / prefetch / suppress 窗口）不依赖像素高度，改动连续模式时勿触碰。
