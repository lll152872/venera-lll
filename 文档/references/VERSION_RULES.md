# Venera 版本号规则

> **适用场景**：发版改版本号时必读。平时开发提交**不要动版本号**。

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

## 相关流程

- 发版完整步骤（改版本号 → 提交 → 打 tag → CI 自动 Release）→ `GIT_WORKFLOW.md` 第 3.3 节
