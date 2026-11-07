# cswap · 命令行对接手册

依据：claude-swap **0.30.0** 源码（tag v0.30.0）与本机实际输出，2026-11-07 核对。真实输出样例在 `fixtures/`：

| 文件 | 命令 |
|---|---|
| `fixtures/list.json` | `cswap list --json` |
| `fixtures/status.json` | `cswap status --json` |
| `fixtures/config.json` | `cswap config list --json` |
| `fixtures/priority.txt` | `cswap priority` |
| `fixtures/log-switch-lines.txt` | 日志里的切换行 |

上游文档（随源码）：README、`docs/json-output.md`（JSON 字段）、`docs/auto-switch.md`（自动切换规则）。

## 1. 读

### `cswap list --json`
顶层：`schemaVersion`（=1）、`activeAccountNumber`、`accounts[]`。每个账号：

| 字段 | 说明 |
|---|---|
| `number`, `email`, `organizationName`, `organizationUuid`, `isOrganization`, `active` | 基本信息 |
| `usageStatus` | `ok` / `token_expired` / `relogin_required` / `api_key` / `keychain_unavailable` / `foreign_credential` / `no_credentials` / `unavailable` |
| `usage.fiveHour` | `pct`（可能 null）、`resetsAt`、`countdown`、`clock`；没有 5 小时窗口的账号（Ultra）整个省略 |
| `usage.sevenDay` | 同上，外加约一天后出现的配速字段 `expectedPct`、`aheadOfPace`、`projectedExhaustionAt`、`willLastToReset` |
| `usage.scoped[]` | 按模型的周窗口（如 Fable），字段同 sevenDay，另有模型名 |
| `usageFetchedAt`, `usageAgeSeconds` | 数据新鲜度 |
| `lastGoodUsage`, `lastGoodAgeSeconds` | `usage` 为 null 时的最后已知读数（只能展示，不能用于判断） |
| `usageError`, `usageRetryAt` | 读取失败原因（如 `http-429`、`timeout`）和下次重试时间 |
| `disabled` | true = 不参与自动轮换；没有该键 = 参与 |
| `threshold` | 单账号阈值；没有 = 跟随全局 |
| `alias` | 别名；没有 = 未设 |
| `loginExpiresAt` | 刷新令牌到期时间（ISO UTC） |
| `plan` | `label`、`tier`、`organizationType`、`billingType`、`subscriptionStatus`、`expired`、`fetchedAt` |

**没有**：优先级（见 `cswap priority`）、令牌详情（`--token-status` 与 `--json` 互斥，会直接报错）、运行中的会话（只在文字版输出里）。

### `cswap status --json`
`active` 对象：当前登录的账号（含 `managed` 是否被 cswap 管理）。用于「刷新」前核对当前登录邮箱。

### `cswap config list --json`
`settings[]`：`key`、`value`、`isSet`。相关 key：`autoswitch.threshold`（默认 90，50–99.9）、`autoswitch.weeklyThreshold`（默认 null，50–99.9）、`autoswitch.cooldownSeconds`（默认 300，0–86400）、`autoswitch.strategy`（best / weekly-first / consume-first / priority-consume-first）、`autoswitch.model`、`autoswitch.includeApiKeyAccounts`、`autoswitch.intervalSeconds`（默认 60）、`autoswitch.hysteresisPct`、`autoswitch.unhealthyTicks`、`ui.theme`、`updates.check`。

### `cswap priority`（文字）
```
Account priorities (higher first; default 0):
  Account-1  alicechen92@example.com  0
  Account-2  BobWilliams8810@example.com  0
Used only by: cswap auto --strategy priority-consume-first
```
解析行：`^\s*Account-(\d+)\s+(\S+)\s+(\d+)\s*$`。

### `cswap --version`
输出 `cswap 0.30.0`。

### 最新版本号
`~/.claude-swap-backup/cache/update_check.json`：`{"timestamp": <unix 秒>, "data": "0.30.0"}`。

### 切换日志
`~/.claude-swap-backup/claude-swap.log`，行格式 `2026-11-06 09:53:23,726 - INFO - Switched from account 2 to 1`。**不区分手动 / 自动**。上游菜单栏用正则 `Switched from account (\d+) to (\d+)` 解析，同样做法。

## 2. 写

| 操作 | 命令 | 备注 |
|---|---|---|
| 切换 | `cswap switch <N> --json` | 返回 `{"switched", "from", "to", "reason"}` |
| 切到余量最多 | `cswap switch --strategy best --json` | |
| 添加当前登录 | `cswap add` | 可带 `--alias NAME` |
| 重新存回某位置 | `cswap add --slot <N>` | 该位置被**另一个**账号占用时会读 stdin 问是否覆盖；App 必须先用 `status --json` 核对邮箱 |
| 移除 | `cswap remove <N>` | **没有跳过确认的参数**，会读 stdin 问 `[y/N]`；App 写入 `y\n`。账号有运行中的会话时拒绝 |
| 别名 | `cswap alias <N> <name>` / `cswap alias <N> --unset` | 只允许 `[a-z0-9_.-]`，强制转小写；App 不再写它，显示名由 App 自己存 |
| 停用 / 启用轮换 | `cswap disable <N>` / `cswap enable <N>` | 停用的账号仍可手动切换 |
| 单账号阈值 | `cswap threshold <N> <pct>` / `--unset` | 50–99.9 |
| 优先级 | `cswap priority <N> <tier>` / `--unset` | 0–1000 |
| 全局设置 | `cswap config set <key> <value>` / `cswap config unset <key>` | 恢复默认用 unset（例如关闭本周单独阈值） |
| 自动切换 | `cswap auto --json` | 常驻进程，一行一个事件：`poll`、`switch`、`no-switch`、`account-quarantined`、`all-exhausted`、`error`；未知类型忽略 |
| 用某个号开终端 | `cswap run <N>` | 只在终端里有意义；App 生成 `.command` 文件交给终端执行 |
| 升级 | `cswap upgrade` | 走 uv；本机安装时用了阿里云镜像 |

## 3. 必须遵守的坑

1. **干净环境**：子进程去掉 `CLAUDE_CONFIG_DIR`。在 `cswap run` 打开的会话里，add / remove / switch 等命令会被拒绝。
2. **stdin 默认接 /dev/null**：防止任何意外的确认提示把子进程挂住。
3. **不要先 /logout 再 add**：Claude Code 的 /logout 可能吊销刚离开那个账号的刷新令牌（上游 README 原文警告）。添加账号的引导文案要写明。
4. **`--token-status` 不能加 `--json`**：会直接报参数错误。
5. **上游菜单栏也会跑自动切换引擎**：两边同时开会重复换号。用户已决定不再装上游菜单栏。
8. **`plan.label` / `plan.expired` 对 Pro 不准**：Pro 与 Free 的额度等级相同，cswap 把有效 Pro 标成 Free、把关掉自动续费的 App Store Pro 标成已到期。以 `organizationType` 为准（规则见 03 §5）。
6. **日志与缓存不是稳定接口**：解析失败就降级隐藏，不报错。
7. **JSON 只增不减**：解码时所有非核心字段都按可选处理，未知字段忽略。
