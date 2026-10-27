# DSH Adapter

`adapters/dsh/` 把 harness-companion 接到 **DeepSeek Harness（DSH）** 上。它是继 `claude-code/`、`codex/` 之后的第三个宿主适配层，遵守同一条边界：**业务语义留在 `core/`，这里只做宿主协议映射**。

## 为什么需要这一层

DSH 与 Claude Code / Codex 的三处差别决定了它不能直接复用旧适配：

| 差别 | 后果 |
|---|---|
| 技能是「目录 + SKILL.md + 按需加载的资源」 | 需要一份 DSH 版入口，把 30k 字符的原版 SKILL.md 压成路由 + 红线 + 资源地图 |
| **没有会话生命周期 hook** | 原版 SessionStart/Stop 的自动注入没有宿主落点，改成显式契约 |
| Windows 上 PATH 里通常没有 bash | 需要 `run.ps1` 解析 Git Bash、透传 argv、兜超时 |
| 没有自定义斜杠命令 | `/harness:status` 等拆成 action 参数 |

## 安装

```powershell
# 默认装到 %DSH_HOME%\skills\harness-companion（DSH_HOME 缺省 ~/.dsh）
./adapters/dsh/install.ps1

# 指定位置
./adapters/dsh/install.ps1 -Target 'D:\tmp\skills\harness-companion'
```

安装器会复制 `SKILL.md`、`references/`（原版 5 篇 + DSH 2 篇）、`core/`、`scripts/`（仅顶层）、`templates/`、`dsh/`、`VERSION`，把 `*.sh` 归一成 LF，并写 `install-receipt.json`。

覆盖策略：目标目录里已有本适配层的收据 → 直接重装；没有收据（比如指向了 `~/.agents/skills`）→ 拒绝，除非 `-Force`（此时旧目录被改名成 `.bak.<时间戳>`，不删除）。

装完**新开一个 DSH 会话**才会出现在技能目录里；当前会话不会热更新。

## 自检

```powershell
& "$env:DSH_HOME\skills\harness-companion\dsh\smoke.ps1"
```

9 项、限时、约 50 秒，覆盖：bash 解析、frontmatter 合规、status、feature list、状态机、verify 产出 NDJSON 证据、`passing` 证据门、WIP=1、consent boundary 零写入。

## 卸载

```powershell
./adapters/dsh/uninstall.ps1
```

只删带 `adapter: dsh` 收据且路径匹配的目录。`~/.agents/skills` 里的 v1 不会被碰。

## 与旧版共存

DSH 的本地技能根按优先级合并（数字小者胜）：项目 `.dsh/skills`(100) → 项目 `.agents/skills`(200) → `<DSH_HOME>/skills`(400) → `~/.agents/skills`(500)。

本机 `~/.agents/skills/harness-companion` 是同一个仓库的 **v1.0.0**。装到 400 号根之后，它会自动被遮蔽——不需要，也不应该为了"干净"去删共享目录。卸载本适配层后 v1 会重新出现。

## 实现要点

- `run.ps1` 只做四件事：找 bash、定位 skill 根、转发 argv、超时。它不解释业务状态。
- **路径规范化**：把 `D:\a\b` 转成 `D:/a/b` 再交给 bash。这不是洁癖——MSYS 的 `sha256sum` 遇到反斜杠路径会切 binary 模式、在哈希前加 `\`，`find` 输出的前缀也剥不掉，结果就是 `config_changed_since_run` 和 `workspace_changed_since_verification` 这类假报警。实测确认过。
- 超时用独立子任务实现，超时退出 124；launcher 自身参数错退出 2；找不到 bash 退出 127。

## 已知边界（诚实）

1. **没有 hooks**。会话开始不自动注入状态、结束不自动提醒交接。SKILL.md 用显式契约补：进入 harness 项目先跑一次 `status`，收尾跑 `handoff`。真正的自动注入需要二期写一个 DSH 插件（监听会话/轮次事件，仍调用同一个 bash 入口）。
2. **`audit` 可能很慢**。本仓库实测 75 秒仍未结束，默认 300 秒超时会被杀掉。审计请显式 `-TimeoutSec 900`，并预期等待。
3. **`verify` 跑项目自己的验证链**。本仓库的链是 `bash tests/run-all.sh`、`timeout_seconds: 14400`。适配层不替你决定跑不跑，但 SKILL.md 要求先看 `.harness/config.json` 再决定范围。
4. **bash core 不移植**。43k 行 POSIX bash 原样复用；Windows 必须装 Git for Windows。
5. **不登记 feature、不产证据链**。仓库 DoD 要求的全量验证链正是拖垮上一次发布的那个环节；适配层改用限时冒烟。等它稳定运行后再补登记，登记的是已验证过的东西。

## 分层边界

`adapters/dsh/` 允许出现：bash 定位、argv 透传、路径方言转换、超时、安装/卸载/冒烟。

不允许出现：WIP 检测、`status=="passing"` 判定、证据关联解析、状态迁移表、指纹算法——这些是 `core/` 的职责。改动前先看 `references/dsh-mapping.md`。

## 开发

源码布局与安装布局不同，脚本会自动识别（向上找 `core/harness-status.sh`）：

```
<repo>/adapters/dsh/run.ps1      源树：skill root = <repo>
<skill>/dsh/run.ps1              安装后：skill root = <skill>
```

改完在源树直接跑 `adapters/dsh/smoke.ps1`，通过后再 `install.ps1` 覆盖安装并跑一次已安装版本的冒烟。

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | DSH 会话入口：路由、六条硬约束、会话边界契约、资源地图 |
| `run.ps1` | 唯一执行入口 |
| `smoke.ps1` | 限时自检 |
| `install.ps1` / `uninstall.ps1` | 安装 / 卸载（收据校验） |
| `references/dsh-execution.md` | 调用配方、引号、退出码、故障排查 |
| `references/dsh-mapping.md` | v2 → DSH 映射、被丢弃的能力及原因、安装布局 |
