# CI analyze 失败诊断

> **适用场景**：CI 构建失败排查（先区分是 analyze job 还是 APK job）。

- Venera CI 的 `analyze` 步骤 `fatal-warnings: true` —— **只要有 warning 级就判 failure**（info 级不致命，`fatal-infos: false`）。
- APK 构建步骤是独立的，analyze 挂 ≠ APK 挂。用户说「构建挂了」时先 `gh run list --limit 5` 区分是哪个 job。
- 查某次 run 为何失败：`gh run view <run_id> --log-failed`。看 `##[warning]` 行即我们的锅。
- **本地验证命令**（权威，不被 LSP 缓存骗）：
  ```bash
  flutter analyze 2>&1 | grep -E "warning -|error -" || echo "OK 无 warning 无 error"
  ```
  只看 warning/error 行；info 级（`deprecated_member_use`）不用管。
- 常见引入的 warning：unused_import（重构后残留的 import）、unused_element（死常量）、invalid_null_aware_operator（`late final` 上用 `?.`）。

## 相关流程

- CI 跳过 / 触发规则、发版 → `GIT_WORKFLOW.md` 第 3 节
