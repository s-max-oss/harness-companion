# Harness Companion（中文）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

**v2.0.0-rc.3（DSH）** — 一个 DeepSeek Harness 技能：为任何项目搭建并维护 Harness Engineering 环境（知识、环境、进度、范围、验证、可观测、交接）。

> **宿主范围**：自 2026 年 10 月起，本仓库只面向 **DeepSeek Harness（DSH）**。Claude Code 与 Codex 适配层已退役，代码与设计记录保留在 git 历史里。

## 它做什么

Harness Engineering 给 AI 代理一套"项目操作系统"。Harness Companion 负责初始化它、体检它、执行它的证据纪律、并干净收尾：

| 子系统 | 文件 | 由谁提供 |
|---|---|---|
| 知识 | `AGENTS.md`、`CLAUDE.md`、`docs/` | 初始化模板 + 审计 |
| 环境 | `init.sh` | 初始化模板 |
| 进度 | `claude-progress.md` | 模板 + 交接 |
| 范围 | `feature_list.json` | WIP=1 状态机 |
| 验证 | `.harness/config.json`、运行日志 | `verify` + 证据门 |
| 可观测 | `.harness/logs/`、`agent.log` | NDJSON 运行日志 |
| 交接 | `session-handoff.md`、清单 | `handoff` |

## 安装

```powershell
# 复制到 %DSH_HOME%\skills\harness-companion
./dsh/install.ps1

# 9 项限时自检，约 50 秒
& "$env:DSH_HOME\skills\harness-companion\dsh\smoke.ps1"
```

之后新开一个 DSH 会话；技能目录在会话开始时读取。

## 使用

加载技能（`/harness-companion`，或直接问"harness 状态"）。所有动作走同一个入口：

```powershell
& "<skill-root>\dsh\run.ps1" status <项目目录>
& "<skill-root>\dsh\run.ps1" feature list <项目目录>
& "<skill-root>\dsh\run.ps1" feature status <项目目录> <id> in_progress
& "<skill-root>\dsh\run.ps1" verify <id> <项目目录> --write
& "<skill-root>\dsh\run.ps1" feature status <项目目录> <id> passing
& "<skill-root>\dsh\run.ps1" handoff <项目目录>
& "<skill-root>\dsh\run.ps1" audit <项目目录> -TimeoutSec 900
```

DSH 没有技能生命周期 hook，所以不会自动注入状态、也不会自动提醒交接。`SKILL.md` 定义了显式契约：进入 harness 项目先跑 `status`，收尾跑 `handoff`。初始化流程保留 consent boundary——完整 Brief 获批前不写任何目标文件。

## 设计原则

- **WIP=1**：最多一个 `in_progress`，状态机会拒绝第二个。
- **证据优先**：`passing` 必须有通过 `evidence_associations` 关联的合法 NDJSON 运行日志，且工作区指纹仍匹配。
- **fail-closed 初始化**：模板快照损坏时停下，而不是静默修复。
- **Brief 是顾问**：当轮用户指令与宿主安全策略始终优先于 `PROJECT_BRIEF.json`。

## 环境要求

- PowerShell 7（安装器、启动器、自检）
- Git for Windows —— 用它的 `bash` 跑语义核心
- 推荐 `jq`（核心在部分路径会回退到 python）

## 目录

```
harness-companion/
├── SKILL.md              # DSH 入口：路由、硬约束、资源地图
├── dsh/                  # 宿主运行时：启动器、安装器、自检、参考
├── core/                 # bash 语义核心（status、feature、verify、audit）
├── scripts/              # 初始化执行器、交接、确认边界
├── templates/            # 项目脚手架
├── references/           # 文件格式、子系统映射、对话原则
└── tests/                # core / init / release 套件 + 夹具
```

## 开发

全量套件是 `bash tests/run-all.sh`（`.harness/config.json` 里超时 4 小时）。日常请跑定向测试：

```bash
bash tests/core/test-status-renderer.sh   # 渲染器 + 证据块
bash tests/core/test-harness-feature.sh   # 状态机
bash tests/core/test-passing.sh           # 证据资格
```

## 许可证

MIT —— 见 [LICENSE](./LICENSE)。
