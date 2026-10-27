---
name: harness-companion
description: 维护 Harness Engineering 项目系统：引导式初始化、7 子系统状态看板、WIP=1 的功能状态机与证据、验证链、会话交接、5 轴审计。当项目含 feature_list.json / AGENTS.md / init.sh，或用户提到 harness、初始化 harness、功能状态、验证证据、交接、审计时使用。
---

# Harness Companion（DSH 宿主适配版）

Harness Engineering 把「怎么可靠地跟代理一起做工程」落成一套项目文件：`AGENTS.md`（知识）、`init.sh`（环境）、`claude-progress.md`（进度）、`feature_list.json`（范围）、验证证据（验证）、日志（可观测）、`session-handoff.md`（交接）。本 skill 是这套系统的运维层——初始化它、体检它、按证据推进它、收尾它。

## 运行约束（先读，能省掉一半白折腾）

- 语义引擎是 POSIX bash。**Windows 上 PATH 里通常没有 bash**（本机 `bash` 命令不存在，Git Bash 在 `C:\Program Files\Git\bin\bash.exe`）。
- 唯一执行入口是本 skill 根目录下的 `dsh/run.ps1`：它自动找 Git Bash、原样透传参数、带超时保护。
- **不要自己拼 `bash ...`**，也不要假设 `core/`、`scripts/` 的相对路径——`run.ps1` 从脚本自身定位 skill 根。
- `/harness:*` 这类斜杠子命令在 DSH 里**不存在**，只有 `/harness-companion` 加载本 skill。六个动作靠下面的路由表由你执行。

调用模板（在 pwsh 工具里）：

```powershell
& "<skill-root>\dsh\run.ps1" <action> [目标目录] [动作参数...] [-TimeoutSec <秒>]
```

执行策略拦截 .ps1 时改用：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\dsh\run.ps1" <action> ...
```

**目标目录是普通位置参数**，按各脚本自己的签名传，不要发明 `-Project` 之类的开关。Windows 风格路径（`D:\work\app`）直接传即可，launcher 会规范成 `/` 形式——这一步不是美化，缺了它 MSYS 的哈希与指纹会把工作区判脏。

## 动作路由

`<dir>` = 目标项目根目录。`run` = `<skill-root>\dsh\run.ps1`。

| 用户意图 | action | 命令形态 |
|---|---|---|
| 项目健康检查 / "harness 状态" | `status` | `run status <dir>` |
| 初始化 / 接管 / 更新脚手架 | `init` | 见下方「初始化」 |
| 看/改功能清单 | `feature` | `run feature list <dir>`；`run feature status <dir> <id> in_progress`；`run feature add <dir> <id> "标题"` |
| 验证功能 / "真的做完了吗" | `verify` | `run verify <feature_id> <dir> --write`（不带 `--write` 只跑不关联） |
| 交接 / 收尾 / 结束会话 | `handoff` | `run handoff <dir>` |
| 审计 / 诊断 | `audit` | `run audit <dir> -TimeoutSec 900` |
| 排查执行环境 | `bash` | `run bash`（打印 bash 路径与版本） |

路径含空格时用单引号包住整个目录：`run status 'D:\my work\app'`。审计请显式放大超时——大型或脏工作区可能跑上几分钟。

## 推进一个功能的正确顺序

顺序错会被证据门拒绝，而且报错看起来像"证据丢了"，其实是工作区变了：

```powershell
& $run feature status <dir> <id> in_progress   # 1. 先切状态（会改 feature_list.json）
& $run verify <id> <dir> --write               # 2. 此时才捕获工作区指纹并关联证据
& $run feature status <dir> <id> passing       # 3. 立刻标 passing，中间不要再改文件
```

反过来"先 verify 再切 in_progress"，`passing` 会报 `workspace_changed_since_verification`——因为切状态本身改动了 `feature_list.json`。这不是 bug，是证据必须对应最终工作区。

同理：`passing` 之前别再手改配置、别再生成别的文件；确实改了，就重跑一次 `verify --write`。

## 六条硬约束（不可协商）

1. **WIP=1**：同一时刻最多一个功能是 `in_progress`。第二个会被脚本拒绝（退出码 4），不要绕过。
2. **证据优先**：功能要变 `passing`，必须有指向合法 run log 的 `evidence_associations`。口头"做完了"不算数；`verify` 产出的 NDJSON 才算法。退出码 5 就是这个拒绝。
3. **初始化先确认**：任何目标项目文件在用户确认完整 Brief 之前都不能写。用户说"就按默认来吧"也不等于确认 Brief。
4. **Brief 字符保真**：用户给的目标与成功标准，从进入 Brief 那刻起按字节保存——不改大小写、不加句号、不拆并条目。要改就明确展示为"修改"，别默默润色。
5. **fail-closed**：`.harness/.template-snapshot.json` 结构损坏、必填字段缺失、快照/摘要不一致时——停下，说明损失，**不要自动修复、不要换个模式重试**。
6. **Brief 是顾问**：当轮用户指令与宿主安全策略永远优先。push / merge / 发版 / 处理凭据 / 装包 / 联网 / 破坏性操作，无论 Brief 怎么写，都要当轮单独授权。

## 会话边界（补 DSH 没有 hook 的空缺）

Claude Code / Codex 版本靠 SessionStart 和 Stop 钩子自动注入状态与交接提醒。DSH 没有这个机制，所以改成**显式契约**——你要主动执行，不要假装有钩子：

- 进入一个含 `feature_list.json` 的项目，第一件事跑一次 `status`，用一到三行说清：几个功能、几个 passing、有没有 WIP 冲突、有没有过期进度。**每轮不要重复刷**。
- 用户说"做完了/好了/能提交了吗"，先 `verify`，再谈是否 `passing`。
- 用户说"收尾/交接/今天到这"，跑 `handoff` 并按输出提醒未提交变更、悬空的 `in_progress`、过期证据。
- 明确告诉用户：这些检查是 skill 执行的动作，不是 DSH 自动行为（除非将来装了插件）。

## 初始化（唯一的高风险动作）

`init` 有三种语义，先判路：

- 全新项目 → **guided**（引导式）：只读勘探 → 补齐 Brief → 展示完整 Brief → 用户明确批准 → 执行。
- 有旧手工文件的项目 → **guided migration**：解释哪些文件早于 Harness 管理、确认 Brief、保留既有文件。
- 已有合法 `.harness/.template-snapshot.json` → **resume**：读回已有 Brief，只讨论有变化的部分。
- `--quick`：不提问不确认，只从当前上下文推断；`goal` 或 `success_criteria` 缺一个就停手不写。**永远不要把它当"省事模式"推荐给用户**。

确认边界只有两条命令：

```powershell
# 取消：不触达 executor，不写目标项目
& "<root>\dsh\run.ps1" boundary <dir> --decision cancel

# 批准：把已展示的 Brief 原样通过 stdin 交给确定性执行器
& "<root>\dsh\run.ps1" boundary <dir> --decision approve --brief-stdin --non-interactive --host=codex -StdinText '<紧凑单行 JSON>'
```

`-StdinText` 里的 JSON 用单引号包裹时双引号是字面量，**不要转义成 `\"`**。Brief 字段名与形状必须先读 `references/project-brief-input.md`，不要猜一个 payload 去试错。

批准之后：把展示给用户的那份 Brief 里的 `goal` 与每条 `success_criteria` 逐字符复制进执行器 JSON，再比对一次。对不上就重新展示，不要带着有损 Brief 初始化。

## 资源地图（按需读，别一次全读）

| 文件 | 什么时候读 |
|---|---|
| `references/project-brief-input.md` | 构造 Brief JSON **之前**（字段名、shape、默认值） |
| `references/conversational-principles.md` | 做 guided init 对话时（提问、冲突处理、四选一菜单） |
| `references/post-init-explanation.md` | init/update 成功之后写说明时（generated/inferred/defaulted/deferred 四类） |
| `references/harness-files.md` | 用户问某个 harness 文件的格式、要不要建 |
| `references/subsystems-mapping.md` | 用户问 7 个子系统、审计维度、课程对应关系 |
| `references/dsh-execution.md` | 命令报错、引号/路径/编码问题、要写新调用方式 |
| `references/dsh-mapping.md` | 想知道原版 hooks/命令在 DSH 里怎么映射、丢了什么 |

## 输出与失败

- **不要 dump JSON**，也不要贴整份 run log。给结论、给证据的指认（run_id、文件名）、给下一步。
- 脚本失败时：保留失败的字段/条件与非零退出码，翻成人话。不要悄悄重试、不要弱化 fail-closed、不要换模式绕。
- 退出码：`0` 成功；`1` 一般失败；`2` 用法/前置条件错；`124` 超时被拦；`127` 找不到 bash 或脚本。
- 超时了先缩小范围（单个 feature、更短的链、`-TimeoutSec`），不要原样再跑一次然后卡住。

## 已知边界（诚实版）

- **没有 hooks**：会话开始不会自动注入状态，收尾不会自动提醒。靠上面的显式契约。
- **没有 `--verbose` 之类原版开关之外的斜杠命令**：动作即参数。
- **`audit` 可能很慢**：它会读全部证据日志与工作区；本仓库实测 75 秒以上仍未结束。默认超时 300 秒，审计请显式放大并预期等待。
- **`verify` 会跑项目自己的验证链**：重项目（比如本仓库配的是 `bash tests/run-all.sh`、超时 4 小时）先看 `.harness/config.json` 再决定范围，别整条跑。
- **bash core 不移植**：43k 行 POSIX bash 原样复用，Windows 依赖 Git Bash。这不是缺陷，是刻意的取舍——重写会立刻与上游分叉。
