# Harness Companion（中文）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

一个用于 [Claude Code](https://claude.ai/code) 的 **Skill + Hooks** 组合工具，为 Harness Engineering（驾驭工程）自动化代理工作流的全部生命周期。它结合了**自动触发的生命周期钩子**和**交互式斜杠命令**，帮助你和 AI 代理保持项目中 harness 文件的健康状态。

## 这是什么？

Harness Engineering 是 [Learn Harness Engineering](https://github.com/walkinglabs/learn-harness-engineering) 课程中提出的一套实践方法，通过 7 个子系统为 AI 代理构建可靠的编码环境。Harness Companion 将这 13 节课的知识转化为可执行的工作流：

| 层级 | 方式 | 做什么 |
|------|------|--------|
| **Hooks**（自动） | SessionStart + Stop 事件 | 会话开始时检查 harness 就绪状态，会话结束时提醒交接收尾 |
| **Commands**（交互） | 6 个斜杠命令 | 初始化脚手架、查看健康仪表盘、管理功能、运行验证、生成交接文档、审计全部 7 个子系统 |

## 快速开始

### 安装

```bash
# 1. 克隆本仓库到 Claude Code 的 skills 目录
git clone https://github.com/s-max-oss/harness-companion.git ~/.claude/skills/harness-companion

# 2. 运行安装脚本注册 hooks
bash ~/.claude/skills/harness-companion/install.sh
```

安装脚本会自动：
- 将 skill 文件复制到 `~/.claude/skills/harness-companion/`（全局）或 `./.claude/skills/harness-companion/`（项目本地）
- 赋予所有脚本可执行权限
- 在 `~/.claude/settings.json` 中注册 SessionStart 和 Stop hooks（安装前自动备份原文件）

### 6 个命令

| 命令 | 触发方式 | 功能 |
|------|---------|------|
| `/harness:init` | "初始化 harness"、"搭建 harness 脚手架" | 从模板生成全套 harness 文件 |
| `/harness:status` | "harness 状态"、"健康检查" | 文件存在性仪表盘、功能进度、WIP=1 检测 |
| `/harness:feature` | "功能列表"、"添加功能"、"更新状态" | 管理 `feature_list.json`（增删改查） |
| `/harness:verify` | "验证功能"、"真的完成了吗" | 运行 typecheck→build→test 验证链，自动填写证据 |
| `/harness:handoff` | "交接"、"结束会话"、"收尾" | 生成 `session-handoff.md`，运行 checklist 验证 |
| `/harness:audit` | "审计 harness"、"诊断" | 对 7 个子系统打分（满分 21），按影响排序给出改进建议 |

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

- [Claude Code](https://claude.ai/code) CLI
- Git Bash（Windows）/ bash（macOS / Linux）
- `jq`（推荐安装，用于功能管理的高级特性；缺失时自动降级为 grep/sed fallback）

## 文件结构

```
harness-companion/
├── SKILL.md                  # Skill 主文档（6 个工作流）
├── README.md                 # 英文说明
├── README.zh-CN.md           # 中文说明（本文件）
├── LICENSE                   # MIT 许可证
├── install.sh                # 一键安装 + hook 注册
├── scripts/
│   ├── harness-init.sh       # 脚手架生成器
│   ├── harness-status.sh     # 健康仪表盘
│   ├── harness-feature.sh    # 功能清单管理
│   ├── harness-verify.sh     # 验证链执行器
│   ├── harness-handoff.sh    # 会话交接文档生成器
│   ├── harness-audit.sh      # 7 子系统审计器
│   └── hooks/
│       ├── session-start.sh  # SessionStart 钩子
│       └── stop-handoff.sh   # Stop 钩子
├── references/
│   ├── harness-files.md      # 完整文件格式参考
│   └── subsystems-mapping.md # 子系统 - 文件 - 课程对照表
└── templates/                # 可直接复制的 harness 文件模板
    ├── AGENTS.md
    ├── CLAUDE.md
    ├── feature_list.json
    ├── init.sh
    ├── claude-progress.md
    ├── session-handoff.md
    ├── clean-state-checklist.md
    └── checklist.sh
```

## Hooks 工作原理

两个 hook 在后台自动运行——无需手动调用：

- **SessionStart**：检测 harness 文件 → 报告健康状态 → 将上下文注入 Claude 的系统提示
- **Stop**：检测未提交变更 → 发现未同步的 `in_progress` 功能 → 提醒执行 `checklist.sh`

Hooks 遵循以下原则：
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

不必须。`jq` 缺失时，脚本自动使用 `grep`/`sed` fallback 处理简单的 JSON 操作。但功能管理（`/harness:feature`）的完整能力需要 `jq`。

**Q: 可以只用 hooks 不用命令，或反过来吗？**

可以。两者是独立的——hooks 负责自动提醒，命令负责交互操作。你可以只使用其中一种。

**Q: 和 claude-mem、superpowers 等其他 skill 冲突吗？**

不冲突。Harness Companion 专注于**项目 harness 文件**的管理，与专注对话记忆的 claude-mem、专注开发流程的 superpowers 互补协作。

## 许可证

MIT — 详见 [LICENSE](./LICENSE)
