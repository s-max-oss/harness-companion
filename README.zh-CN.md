# Harness Companion（中文）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

**v2.0.0-rc.2** — 一个面向 AI 代理的 Skill + Hooks 工具集，为 Harness Engineering（驾驭工程）自动化代理工作流的全部生命周期。它结合了**自动触发的生命周期钩子**和**交互式斜杠命令**，并原生支持 **Claude Code** 与 **Codex** 两大代理。

## 架构（v2 — Core / Adapter 分层）

```
┌─────────────────────────────────────────────────────┐
│             宿主代理（Claude Code / Codex）          │
└─────────────────┬───────────────────────┬───────────┘
                  │                       │
       adapters/claude-code/      adapters/codex/
                  │                       │
                  └─────────┬─────────────┘
                            │
                            ▼
                  ┌───────────────────┐
                  │   core/  (引擎)   │   ← 纯 bash，无宿主依赖
                  │  + libs（15 文件）│
                  └───────────────────┘
                            ▲
                            │
              scripts/  (v1 兼容 wrapper — 每文件 ≤5 行)
                            │
                  ┌───────────────────┐
                  │  SKILL.md (入口)  │
                  └───────────────────┘
```

- **Core** 拥有全部业务语义：feature 跟踪、证据、审计、状态渲染、run-log 校验、工作区指纹、锁注册表。
- **Adapter** 仅做宿主协议映射：stdin JSON、fail-open 陷阱、宿主信封包装（Claude `hookSpecificOutput.additionalContext` / `systemMessage`；Codex `SessionStart` / `Stop` / `PreToolUse`）。
- **scripts/** 是薄薄的 v1 兼容层（`exec bash ../core/<name>`），旧版 `/harness:*` 调用方无需改动。

## 这是什么？

Harness Engineering 是一套为 AI 代理构建可靠编码环境的实践方法，通过 7 个子系统落地。Harness Companion 将这些知识转化为可执行的工作流：

| 层级 | 方式 | 做什么 |
|------|------|--------|
| **Hooks**（自动） | SessionStart + Stop 事件 | 会话开始时检查 harness 就绪状态，会话结束时提醒交接收尾 |
| **Commands**（交互） | 6 个斜杠命令 | 初始化脚手架、查看健康仪表盘、管理功能、运行验证、生成交接文档、审计全部 7 个子系统 |
| **Adapters** | Claude Code + Codex | 原生协议映射；可单独安装，也可同时安装两者 |

## 快速开始

### 两种安装生命周期 — 请勿混用

Harness Companion 支持两种独立的安装方式。**选择其一**并坚持使用——交叉管理会导致冲突。

**方式 A — Claude Code 市场（插件管理）：**

```bash
# 从本地仓库添加
claude plugin marketplace add .

# 或从 GitHub 添加
claude plugin marketplace add s-max-oss/harness-companion

# 安装并查看详情
claude plugin install harness-companion@harness-engineering
claude plugin details harness-companion@harness-engineering

# 卸载
claude plugin uninstall harness-companion@harness-engineering
```

**方式 B — 手动适配器安装（install.sh + uninstall.sh）：**

```bash
# 克隆
git clone https://github.com/s-max-oss/harness-companion.git

# 安装（默认：Claude Code adapter）
bash harness-companion/install.sh                          # 全局安装
bash harness-companion/install.sh --project                # 项目本地
bash harness-companion/install.sh --codex                  # Codex adapter
bash harness-companion/install.sh --all                    # 同时安装两者

# 也可直接调用 adapter 安装器
bash harness-companion/adapters/claude-code/install.sh
bash harness-companion/adapters/codex/install.sh --repo ~/my-project
bash harness-companion/adapters/codex/install.sh --user

# 卸载
bash harness-companion/uninstall.sh                        # Claude（默认）
bash harness-companion/uninstall.sh --codex                # Codex
bash harness-companion/uninstall.sh --all                  # 全部
bash harness-companion/adapters/claude-code/uninstall.sh   # 直接调用适配器路径
```

安装脚本会自动：
- 复制 `core/`、`adapters/<x>/`、`templates/`、`references/`、`scripts/`（v1 wrapper）到目标目录
- 在 `~/.claude/settings.json` 中注册 SessionStart 和 Stop hooks（自动合并已有条目；幂等；修改前备份）
- Codex 模式：写入 `.codex/hooks.json`（repo-local）或 `~/.codex/harness-hooks.toml`（user）
- 写入 `install-receipt.json`（含版本、源 commit、SHA-256 完整性清单）

卸载脚本会：
- 通过 `install-receipt.json` 验证目标身份（receipt gate — 拒绝非 harness-companion 路径）
- 拒绝删除空路径/根目录/家目录（target gate）
- 从 `settings.json` 注销 hooks（fail-closed：JSON 损坏时拒绝修改）
- 删除目标目录；报告需手动清理的项目

### 6 个命令

| 命令 | 触发方式 | 功能 |
|------|---------|------|
| `/harness:init` | "初始化 harness"、"搭建 harness 脚手架" | 从模板生成全套 harness 文件（AGENTS.md、CLAUDE.md、feature_list.json、init.sh 等） |
| `/harness:status` | "harness 状态"、"健康检查" | 文件存在性仪表盘、功能进度、WIP=1 检测 |
| `/harness:feature` | "功能列表"、"添加功能"、"更新状态" | 管理 `feature_list.json`（增删改查） |
| `/harness:verify` | "验证功能"、"真的完成了吗" | 运行 typecheck→build→test 验证链，自动填写证据 |
| `/harness:handoff` | "交接"、"结束会话"、"收尾" | 生成 `session-handoff.md`，运行 checklist 验证 |
| `/harness:audit` | "审计 harness"、"诊断" | 对 7 个子系统打分（满分 21），按影响排序给出改进建议 |

## Adapters

| Adapter | Hook 事件 | 输出路径 | 备注 |
|---------|-----------|----------|------|
| **Claude Code** | SessionStart, Stop | `~/.claude/skills/harness-companion/` | 默认。`hookSpecificOutput.additionalContext` 注入状态；`systemMessage` 发送 handoff 警告。 |
| **Codex** | SessionStart, Stop, PreToolUse | `<project>/.codex/` 或 `~/.codex/` | 代码完成，运行时 E2E 待验证。PreToolUse 当前为 permissive（策略未启用）。`.codex-plugin/plugin.json` 支持 Codex 市场。 |

## 7 个子系统

Harness Companion 围绕 [Learn Harness Engineering](https://github.com/walkinglabs/learn-harness-engineering) 课程中的 7 个子系统构建：

| # | 子系统 | 核心文件 | 课程 |
|---|--------|---------|------|
| 1 | **Knowledge**（知识） | `AGENTS.md`、`CLAUDE.md`、`docs/` | L02-L03 |
| 2 | **Environment**（环境） | `init.sh` | L04 |
| 3 | **Progress**（进度） | `claude-progress.md` | L05-L06 |
| 4 | **Scope/Feature**（范围/功能） | `feature_list.json` | L07-L08 |
| 5 | **Verification**（验证） | `checklist.sh`、测试套件 | L09-L10 |
| 6 | **Observability**（可观测） | `agent.log`、`evaluator-rubric.md` | L11 |
| 7 | **Handoff/Loop**（交接/循环） | `session-handoff.md`、`clean-state-checklist.md`、`loop.sh` | L12-L13 |

## 环境要求

- **Claude Code**（使用 Claude Code adapter 时） — https://claude.ai/code
- **Codex CLI**（使用 Codex adapter 时）
- Git Bash（Windows）/ bash（macOS / Linux）
- `jq`（推荐安装）— 用于 `/harness:feature` 与 run-log 校验
- `python3`（可选）— 在没有 `jq` 的环境下构造 Codex `hooks.json` 的回退方案

JSON 运行时回退顺序：`python3 → python → py -3 → jq → powershell`，并带有真实执行探测（不接受 `command -v` 的 stub 结果）。

## 文件结构

```
harness-companion/
├── SKILL.md                       # Skill 主文档（6 个工作流）
├── README.md                      # 英文说明
├── README.zh-CN.md                # 中文说明（本文件）
├── CHANGELOG.md                   # 版本历史
├── LICENSE                        # MIT 许可证
├── install.sh                     # 顶层分发器（默认 Claude Code，支持 --codex/--all）
├── core/                          # 纯 bash 语义核心（不感知宿主）
│   ├── harness-audit.sh
│   ├── harness-feature.sh
│   ├── harness-status.sh
│   ├── harness-verify.sh
│   └── lib/                       # 15 个 lib 文件
├── adapters/
│   ├── claude-code/               # Claude Code 协议映射
│   │   ├── hooks/                 # session-start.sh, stop-handoff.sh
│   │   └── install.sh
│   └── codex/                     # Codex 协议映射（Phase 5b）
│       ├── hooks/
│       ├── adapter.conf
│       ├── PHASE5B_STATUS.md      # Codex 状态说明（规范措辞）
│       ├── install.sh             # 3 种模式：plugin / --repo / --user
│       └── uninstall.sh
├── .codex-plugin/
│   ├── plugin.json                # Codex plugin 清单（v 2.0.0-rc.1）
│   └── skills/                    # Codex 可发现的 skill bundle
├── hooks/
│   ├── hooks.json                 # Codex 事件键控的 hook 注册表
│   └── README.md
├── scripts/                       # v1 兼容 wrapper（每文件 ≤5 行）
│   ├── harness-init.sh            # ← 原生实现（生成 AGENTS.md、CLAUDE.md、feature_list.json、init.sh）
│   ├── harness-handoff.sh         # ← 原生实现（生成 session-handoff.md、运行 checklist.sh）
│   ├── harness-audit.sh           # → ../core/harness-audit.sh
│   ├── harness-feature.sh         # → ../core/harness-feature.sh
│   ├── harness-status.sh          # → ../core/harness-status.sh
│   ├── harness-verify.sh          # → ../core/harness-verify.sh
│   └── hooks/
│       ├── session-start.sh       # → ../../adapters/claude-code/hooks/session-start.sh
│       └── stop-handoff.sh        # → ../../adapters/claude-code/hooks/stop-handoff.sh
├── references/
│   ├── harness-files.md           # 完整文件格式参考
│   └── subsystems-mapping.md      # 子系统 - 文件 - 课程对照表
├── templates/                     # 可直接复制的 harness 文件模板（8 文件）
└── tests/                         # 277+ 测试，覆盖 core/、golden/、adapters/
    ├── core/
    ├── golden/
    └── adapters/
```

## Hooks 工作原理

两个 Claude Code hook 在后台自动运行——无需手动调用：

- **SessionStart**：检测 harness 文件 → 报告健康状态 → 将上下文注入 Claude 的系统提示（`hookSpecificOutput.additionalContext`）
- **Stop**：检测未提交变更 → 发现未同步的 `in_progress` 功能 → 提醒执行 `checklist.sh`（`systemMessage`）

三个 Codex hook：

- **SessionStart**：相同的状态注入逻辑，映射到 Codex 的 `hookSpecificOutput`
- **Stop**：相同的 handoff 警告，映射到 Codex `systemMessage`
- **PreToolUse**：当前 permissive fail-open（Phase 5b 暂未启用策略）

所有 hook 遵循：
- **非阻塞**：始终返回 `{"continue":true}`，不中断会话
- **优雅降级**：非 harness 项目（无 `feature_list.json`）静默退出
- **快速执行**：5 秒超时，超时自动放行

## 关键设计理念

### WIP=1 原则

同一时间只允许一个功能处于 `in_progress` 状态。这是课程第 7 课的核心原则——避免多任务切换造成的上下文丢失，确保每个功能在开始下一个之前被充分验证。

### 证据优先

功能不能仅靠口头声明"已完成"。必须通过 typecheck → build → test 验证链，并将命令输出作为 `evidence` 记录在 `feature_list.json` 中。`/harness:verify` 强制执行这一原则。

### 渐进式披露

AGENTS.md 作为入口文档，链接到详细文档，而不是把所有信息塞进一个文件。`/harness:audit` 会标记超过 500 行的 AGENTS.md。

## 常见问题

**Q: 我的项目没有 harness 文件，hooks 会报错吗？**

不会。hooks 检测到没有 `feature_list.json` 后会静默退出，完全不影响正常使用。

**Q: 必须安装 jq 吗？**

不必须。`jq` 缺失时，脚本自动使用 `python3 → python → py -3 → powershell` 的回退链来处理 JSON 操作。但功能管理（`/harness:feature`）的完整能力需要 `jq`。

**Q: 可以只用 hooks 不用命令，或反过来吗？**

可以。两者是独立的——hooks 负责自动提醒，命令负责交互操作。你可以只使用其中一种。

**Q: 和 claude-mem、superpowers 等其他 skill 冲突吗？**

不冲突。Harness Companion 专注于**项目 harness 文件**的管理，与专注对话记忆的 claude-mem、专注开发流程的 superpowers 互补协作。

## 许可证

MIT — 详见 [LICENSE](./LICENSE)

---

项目仓库：https://github.com/s-max-oss/harness-companion