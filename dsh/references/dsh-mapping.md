# v2 → DSH 映射

本文件解释「原版在 Claude Code / Codex 里靠宿主协议做的事，在 DSH 里落到哪里」。改 adapter 之前先读它，别把业务语义塞进来。

## 1. 总表

| v2 概念 | Claude Code / Codex 落点 | DSH 落点 |
|---|---|---|
| Skill 入口 | `~/.claude/skills/harness-companion` + hooks | `<DSH_HOME>/skills/harness-companion/SKILL.md`（技能目录，按需加载） |
| 斜杠命令 `/harness:init` 等 | 宿主命令系统 | `run.ps1` 的 action 参数；人类可 `/harness-companion` 唤醒本 skill |
| SessionStart 状态注入 | hook + `hookSpecificOutput.additionalContext` | 无 hook。`SKILL.md` 的「会话边界」契约：进入 harness 项目先跑一次 `status` |
| Stop 交接提醒 | hook + `systemMessage` | 无 hook。「收尾/交接」时跑 `handoff` |
| PreToolUse | Codex hook（本来就 permissive） | 丢弃 |
| 安装器 | `adapters/{claude-code,codex}/install.sh`（已退役） | `dsh/install.ps1`（复制到 `%DSH_HOME%\skills`） |
| 安装收据 | `install-receipt.json`（含 sha256 清单、升级历史） | 精简收据：身份 + 版本 + 来源 + 时间。够卸载校验用，不做全量哈希 |
| 业务语义 | `core/` | **不变**，原样复制 |
| 宿主协议映射 | `adapters/*/hooks/*.sh` | `dsh/run.ps1`（bash 解析 + argv 透传 + 超时） |

## 2. 丢掉的东西，以及为什么

### hooks 的两个自动时机

原版在会话开始注入健康状态、结束时提醒交接。DSH 到当前版本**没有**可注册的会话生命周期钩子给技能用（插件层可以监听事件，但那是二期，且需要写 Cordis 插件）。

代价：**「说到就做」可以，「不问就做」不行**。这不是实现偷懒，是宿主能力缺口。补法只有两条：

1. 指令层（本版）：`SKILL.md` 规定动作时点，模型照做。
2. 插件层（可选二期）：写一个 DSH 插件，在 session start / 轮次结束时调用同一个 bash 入口，注入文本。业务语义仍然在 core，插件只做协议映射——符合原版的分层。

### 命令注册

DSH 的自定义斜杠命令需要插件 `ctx.commands.register()`。技能本身只支持 `/name` 唤醒。所以 `/harness:status` 这类拆成：

- 模型侧：意图识别 → action
- 人类侧：`/harness-companion` 后跟自然语言（"看一下状态"）

### 全量验证链

原版 DoD 要求 `core/harness-verify.sh` 产出 `overall_result=passed` 的证据。本仓库自己的配置是 `bash tests/run-all.sh`、`timeout_seconds: 14400`。DSH 适配层**不纳入**这条链：交付用 `dsh/smoke.ps1`（限时、只读、覆盖入口与关键动作）。

取舍理由：适配层是新宿主映射，不该被主仓库的全量套件绑架；等它稳定运行后再补登记 feature 与证据更合理。

## 3. 安装布局

```
%DSH_HOME%\skills\harness-companion\
├── SKILL.md                    # DSH 入口（本适配层）
├── references\
│   ├── harness-files.md        # 原版 5 篇
│   ├── subsystems-mapping.md
│   ├── conversational-principles.md
│   ├── project-brief-input.md
│   ├── post-init-explanation.md
│   ├── dsh-execution.md        # 本适配层
│   └── dsh-mapping.md
├── core\                       # 业务语义（原样）
├── scripts\                    # 原生实现 + v1 兼容 wrapper（原样）
├── templates\                  # 脚手架模板（原样）
├── dsh\
│   ├── run.ps1                 # 唯一执行入口
│   └── smoke.ps1               # 限时自检
├── VERSION
└── install-receipt.json
```

`DSH_HOME` 缺省是 `~/.dsh`（本机 `C:\Users\<user>\.dsh`）。可用 `-Target` 覆盖。

## 4. 发现与优先级

DSH 只扫一层：`<root>/<name>/SKILL.md`。本机相关根与优先级（小者胜）：

| 优先级 | 根 | 说明 |
|---|---|---|
| 100 | `<project>/.dsh/skills` | 项目级，最高 |
| 200 | `<project>/.agents/skills` | 项目级共享 |
| 400 | `<DSH_HOME>/skills` | **本适配层安装位置** |
| 500 | `~/.agents/skills` | 跨工具共享；这里存在同一个仓库的 **v1.0.0** |

结论：本适配层（400）会自动遮蔽 `~/.agents/skills` 里的 v1（500），**不要为了 "干净" 去删旧目录**——那个目录其他 CLI 也在用。要回退到 v1，卸掉本适配层即可。

`name` 必须 kebab-case，且 `description` 在会话目录里会被截到 500 字符；改 frontmatter 后新会话才看得到（本会话目录不会热更新）。

## 5. 收据

```json
{
  "adapter": "dsh",
  "version": "2.0.0-rc.3",
  "mode": "user",
  "installed_at": "2026-10-26T12:00:00Z",
  "installed_to": "C:\\Users\\<user>\\.dsh\\skills\\harness-companion",
  "source": { "repository": "harness-companion", "commit": "<sha|null>", "origin": "git|archive" }
}
```

卸载时校验 `adapter == dsh` 且 `installed_to` 与目标一致，防止把别人的目录删了。重装覆盖自己；目标存在但没有本适配层收据时，安装器拒绝并提示 `-Force`。

## 6. 分层边界（硬约束）

- `dsh/` **只做宿主映射**：找 bash、转发参数、超时、安装、自检。
- 不许出现业务判定：WIP 检测、证据比对、状态机、`fingerprint` 一律留在 `core/`。
- `SKILL.md` 是对话层，不是语义层：它规定"什么时候跑哪个动作"，不重新实现动作。
- 检查方式：`dsh/` 里出现 `status=="passing"` 判定、`evidence_associations` 解析、状态迁移表之类的代码，就是越界。

## 7. 版本与升级

适配层跟随仓库 `VERSION`（当前 `2.0.0-rc.3`），不单独发版。core 升级后重跑 `install.ps1` 即可；收据里的 `installed_at` 更新，`source.commit` 反映来源。旧版 DSH 适配层没有 `upgrade_history`——刻意精简，重装语义就是"用当前源码覆盖"。需要回滚就重新装回旧源码树。
