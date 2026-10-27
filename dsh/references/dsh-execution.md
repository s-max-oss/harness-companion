# DSH 执行参考

本文件只在**调用出问题**或**要写新的调用方式**时读。日常按 `SKILL.md` 的路由表照抄即可。

## 1. 为什么需要 `run.ps1`

核心引擎是 POSIX bash，而 DSH 在 Windows 上通常没有 `bash` 在 PATH 里：

```powershell
Get-Command bash      # 本机：不存在
```

但 Git for Windows 自带 Git Bash（本机实测 `C:\Program Files\Git\bin\bash.exe`，版本 5.2.37）。`run.ps1` 做四件事：

1. 找 bash：`$env:DSH_BASH` → PATH 里的 `bash` → `%ProgramFiles%\Git\bin\bash.exe` → `%ProgramFiles(x86)%\...` → `%LOCALAPPDATA%\Programs\Git\bin\bash.exe` → `C:\Program Files\Git\usr\bin\bash.exe` → `/bin/bash`。第一个真实可执行的胜出（用 `--version` 探活，不认 stub）。
2. 定位 skill 根：从脚本位置向上找含 `core/harness-status.sh` 的目录。源代码树（`dsh/`）和安装后（`<skill>/dsh/`）两种布局都成立。
3. 转发 argv：`& $bash $script @rest`，不经 `cmd.exe`、不做二次引号处理。带空格、带中文、带 `--flag=value` 的参数都安全。
4. 超时：默认 300 秒，超时杀进程并退出 124，不会让会话挂死。

## 2. 调用形状

### 通用

```powershell
& "<skill-root>\dsh\run.ps1" <action> [动作参数...] [-TimeoutSec <秒>]
```

**目标目录就是动作参数**，按脚本签名传位置参数；不要发明 `-Project` 之类开关。launcher 在当前目录执行脚本，所以相对目标 `.` 会解析到当前会话目录。

### 各动作

```powershell
# 只读体检
& $run status $dir

# 功能清单
& $run feature list $dir
& $run feature add $dir feat-login "登录功能"
& $run feature status $dir feat-login in_progress
& $run feature status $dir feat-login passing

# 验证（不带 --write 只跑不关联；带 --write 才写 evidence_associations）
& $run verify feat-login $dir --write -TimeoutSec 900

# 交接
& $run handoff $dir

# 审计（慢，显式放大超时）
& $run audit $dir -TimeoutSec 900

# 诊断
& $run bash
```

注意 `feature` 的两种签名：`list <dir>` 是"子命令在前、目标在后"；`add/status` 是"子命令、目标、id、状态"。`verify` 是"功能 id 在前、目标目录在后"。照抄，别自己调序。

### 初始化（consent boundary）

```powershell
# 取消：executor 不会被调用，目标项目零写入
& $run boundary $dir --decision cancel

# 批准
& $run boundary $dir --decision approve --brief-stdin --non-interactive --host=codex -StdinText '<紧凑单行 JSON>'
```

**目标目录必须是第一个位置参数**：`boundary` 与 `init` 的第一个参数是 target，少传会直接掉进 usage（退出码 2）。这是最容易踩的一脚——不要只传 `--decision`。

要点：

- `-StdinText` 后面用**单引号**包整段 JSON，里面双引号是字面量。不要写 `\"`。
- JSON 字符串里有单引号时写成两个单引号 `''`。
- 不要用 PowerShell here-string 或 base64 包一层。
- Brief 很大时用 `-StdinFile <path>` 从文件读，避免命令行长度限制。
- **执行前**先读 `references/project-brief-input.md`，按 schema 的规范拼写（`stack: node`、`test_framework: jest`），别用展示用变体。

### 原文 dry-run / apply（`--update`）

```powershell
$brief = '<确认过的同一份紧凑 JSON>'
& $run init $dir --brief-stdin --non-interactive --host=codex --update -StdinText $brief
# 读到 plan token 后，逐字复制上一条命令，只追加：
& $run init $dir --brief-stdin --non-interactive --host=codex --update --apply --plan-token <token> -StdinText $brief
```

两次调用必须是同一份 payload、同一种传输方式；中间不要重新生成字段。

## 3. 引号与路径

| 情况 | 写法 |
|---|---|
| 路径含空格 | 单引号包：`$run status 'D:\my work\app'` |
| 路径含中文 | 同上；bash 侧同时接受 `D:/x` 与 `D:\x` |
| 参数以 `-` 开头 | 原样传；launcher 只拦截 `-TimeoutSec` / `-StdinText` / `-StdinFile` 三个自己的开关 |
| 需要脚本自身的 `--help` | `$run run core/harness-audit.sh --help` |

## 4. 编码

- Git Bash 输出 UTF-8，`run.ps1` 在子任务里把 `[Console]::OutputEncoding` 固定为 UTF-8。否则中文与制表线会变成 `鈹€` 这类乱码。
- 证据日志（NDJSON）由 `core/lib/evidence.sh` 写入，别手改。

## 5. 行尾

源码树在 `core.autocrlf=true` 的 Windows 克隆里是 CRLF（本仓库 183 个文件如此）。多数脚本仍能跑，但个别 heredoc / `set -e` 组合会出怪问题。安装器会在复制后把 `*.sh` 统一转成 LF；**不要**在安装目录里手工改文件，重装会覆盖。

## 6. 退出码

| 码 | 含义 | 处理 |
|---|---|---|
| 0 | 成功 | — |
| 1 | 一般失败（脚本自身判定） | 读输出里的失败条件，别重试 |
| 2 | 用法/前置条件错（含 launcher 参数错） | 修参数；常见于漏传目标目录 |
| 3 | 非法状态迁移（feature 状态机） | 看合法迁移表，别硬改 JSON |
| 4 | WIP 超限（已有 `in_progress`） | 先把当前那个收尾 |
| 5 | passing 缺证据 | 跑 `verify --write` |
| 6 | 需要 `--override` 才能标 unverified | 先问用户要不要保留证据纪律 |
| 7 | 注册表锁超时 | 等一会儿或查残留锁 |
| 124 | `run.ps1` 超时被杀 | 缩范围或放大 `-TimeoutSec`，别原样重跑 |
| 127 | 找不到 bash / 脚本 | `$run bash` 看诊断结果 |

状态机的合法迁移（摘自 `core/harness-feature.sh`）：

```
not_started → in_progress | blocked | deprecated
in_progress → passing | blocked | not_started | deprecated
blocked     → in_progress | not_started | deprecated
unverified  → in_progress | blocked | passing | deprecated
passing     → in_progress | deprecated
deprecated  → in_progress | not_started
```

`not_started → passing` 不合法（退出码 3）：必须先 `in_progress`，再在证据到位后 `passing`。

## 7. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `bash: NOT FOUND` | 没装 Git Bash 或 `DSH_BASH` 指错 | 装 Git for Windows；或 `$env:DSH_BASH='C:\...\bash.exe'` |
| `无法加载文件 ... 未数字签名` | PowerShell 执行策略 | `pwsh -NoProfile -ExecutionPolicy Bypass -File <run.ps1> ...` |
| 输出全是 `鈹€`/`锛` | 解码用了 ANSI 代码页 | 用 `run.ps1`，不要自己 `& bash` |
| `$'\r': command not found` | CRLF 脚本 | 重装（安装器会转 LF），别手改 |
| `jq: command not found` | 缺 jq | 装 jq，或让脚本走 python/powershell 回退链；`feature` 的完整能力依赖 jq |
| 命令跑很久没动静 | 验证链本身长，或 `audit` 在扫工作区 | `-TimeoutSec` 控制；先 `status` 定位再决定范围 |
| stdin 卡住 | 用了 `--brief-stdin` 但没给 `-StdinText`/`-StdinFile` | 补 stdin；别在无 stdin 时调 boundary |
| `Usage: harness-init-boundary.sh ...` | 漏了 target 位置参数 | `$run boundary <dir> --decision cancel` |

## 8. 不要做的事

- 不要绕过 `run.ps1` 直接 `bash core/...`：相对路径、CRLF、编码三者会一起咬你。
- 不要在目标项目里手工改 `feature_list.json` 的 `status`：状态机、锁、revision 都会失配。
- 不要手搓 NDJSON run log：一律由 `$run verify` 生成。
- 不要为了"跑通"把 fail-closed 检查改成放行。
