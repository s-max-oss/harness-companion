# DSH runtime

`dsh/` 是 harness-companion 在 DeepSeek Harness（DSH）上的运行时层。仓库现在只服务 DSH 一个宿主：Claude Code 与 Codex 适配层已退役（历史见 `git log` 与 CHANGELOG）。

## 为什么需要这一层

| DSH 的事实 | 后果 |
|---|---|
| 技能是「目录 + SKILL.md + 按需加载的资源」 | 入口在仓库根 `SKILL.md`，资源保持相对路径 |
| **没有会话生命周期 hook** | 原版靠 hook 自动注入状态/交接提醒，现在改成 SKILL.md 里的显式契约 |
| Windows 上 PATH 里通常没有 bash | `run.ps1` 解析 Git Bash、透传 argv、规范化路径、兜超时 |
| 没有自定义斜杠命令 | 六个动作变成 `run.ps1 <action>` |

## 安装

```powershell
# 默认装到 %DSH_HOME%\skills\harness-companion
./dsh/install.ps1

# 指定位置
./dsh/install.ps1 -Target 'D:\tmp\skills\harness-companion'
```

安装器复制根 `SKILL.md`、`references/`、`core/`、`scripts/`（仅顶层）、`templates/`、`dsh/`、`VERSION`，把 `*.sh` 归一为 LF，并写 `install-receipt.json`。覆盖策略：有本适配层收据 → 直接重装；无收据 → 拒绝，除非 `-Force`（旧目录改名 `.bak.<时间戳>`，不删除）。

装完新开一个 DSH 会话才会出现在技能目录里。

## 自检

```powershell
& "$env:DSH_HOME\skills\harness-companion\dsh\smoke.ps1"
```

9 项、约 50 秒：bash 解析、frontmatter、status、feature list、状态机、NDJSON 证据、`passing` 证据门、WIP=1、consent boundary。

## 卸载

```powershell
./dsh/uninstall.ps1
```

只删带 `adapter: dsh` 收据且路径匹配的目录。

## 实现要点

- `run.ps1` 只做四件事：找 bash、定位技能根、转发 argv、超时（默认 300s，退出码 124）。
- **路径规范化**：`D:\a\b` → `D:/a/b`。不是洁癖——MSYS 的 `sha256sum` 遇到反斜杠路径会切 binary 模式并在摘要前加 `\`，`find` 输出的前缀也剥不掉，结果就是 `config_changed_since_run` / `workspace_changed_since_verification` 假报警。
- **jq 的 CRLF**：MSYS 下 `jq.exe` 输出 CRLF，`read` 得到的 run id 会带 `\r`，拼出的 NDJSON 路径永远不存在。`core/lib/status-renderer.sh` 在所有 jq 读取点统一 `tr -d '\r'`。
- **Stop 语义**：DSH 没有 hook，这条只影响手动 `handoff`；run-log 校验按 `HC_HANDOFF_BUDGET_SEC`（默认 3s）截断并报告进度。

## 已知边界

1. 没有 hooks：状态检查与交接提醒靠显式契约，不会自动触发。
2. `audit` 可能很慢：会读全部证据日志与工作区，建议 `-TimeoutSec 900`。
3. `verify` 跑项目自己的验证链：本仓库配的是 `bash tests/run-all.sh`，别整条乱跑。
4. bash core 不移植：43k 行 POSIX bash 原样复用，Windows 依赖 Git for Windows。
5. `install.ps1` / `run.ps1` 需要 PowerShell 7。

## 目录

| 文件 | 作用 |
|---|---|
| 根 `SKILL.md` | DSH 会话入口：路由、六条硬约束、会话边界契约、资源地图 |
| `dsh/run.ps1` | 唯一执行入口 |
| `dsh/smoke.ps1` | 限时自检 |
| `dsh/install.ps1` / `uninstall.ps1` | 安装 / 卸载（收据校验） |
| `dsh/references/dsh-execution.md` | 调用配方、引号、退出码、故障排查 |
| `dsh/references/dsh-mapping.md` | 原多宿主设计的映射记录（历史） |
