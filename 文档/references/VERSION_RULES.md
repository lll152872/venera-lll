# Venera 版本号规则

> **适用场景**：发版改版本号时必读。平时开发提交**不要动版本号**。

- 版本号由用户（release 时）指定，**不要自己随意改**。
- **格式（自 v2.4.1 起统一为三位版本号）**：
  - 对外发布 / Release tag 用三位版本号，如 `v2.4.1`。
  - `pubspec.yaml` 内部 `version:` 字段写为 `x.y.z+build`（build 单调自增，如 `2.4.1+241`）。
  - `lib/foundation/app.dart` 的 `final version` 写为 `"x.y.z"`（不含 build 号）。
  - 三者（tag / pubspec / app.dart）版本号必须一致，否则关于页面显示的是 app.dart 里的值。
- **历史说明**：v2.4.1 之前的 Release tag 为两位（`v2.0` … `v2.4`），按本规则等价于 `v2.0.0` … `v2.4.0`。从 v2.4.1 起统一改为三位，不再回退到两位。
- 平时开发提交不要动版本号，也不要动 `pubspec.lock`（本地 analyze 若改动需 `git checkout` 还原）。

## 相关流程

- 发版完整步骤（改版本号 → 提交 → 打 tag → CI 自动 Release）→ `GIT_WORKFLOW.md` 第 3.3 节
