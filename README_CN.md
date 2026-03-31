[English](README.md)

<div align="center">
  <img src="assets/logo.png" width="291" alt="Loopwise Logo">
</div>

# Loopwise: 自动化计划/代码评审工具

Claude Code 与 Codex CLI 之间的自动化 review 循环。利用两个顶级 AI 模型（Claude Opus 4.6 + GPT-5.4）互相审查，产出质量显著高于单模型输出。

Claude Code 生成计划或代码，Codex 自动审查，反馈回传给 Claude Code 进行修改，循环往复直到 Codex 批准通过。

## 工作原理

```
┌─────────────┐    计划/代码        ┌─────────────┐
│ Claude Code │ ─────────────────→ │   Codex     │
│  （生成）    │                    │  （审查）     │
│             │ ←───────────────── │             │
│  （修改）    │      反馈           │             │
└─────────────┘                    └─────────────┘
       ↑                                 │
       └──── 循环直到 APPROVED ───────────┘
```

每一轮：
1. Claude Code 生成输出（计划或代码）
2. Codex 通过 `codex exec` 按质量标准审查
3. 如果 Codex 输出 APPROVED，循环结束
4. 否则，反馈回传给 Claude Code 进行修改
5. 重复直到通过或达到最大轮数

**适用场景：**
- 架构设计文档评审
- 重构计划可行性检查
- 代码实现审查
- 任何需要"第二双眼睛"的场景

**两种使用方式：**
- `/loopwise` — Claude Code 内的斜杠命令（推荐）
- `loopwise` — 独立 shell 命令

## 教程

查看 [docs/TUTORIAL.md](docs/TUTORIAL.md) 获取包含真实评审案例的详细教程。也提供 [English version](docs/TUTORIAL_EN.md)。

## 前置要求

```bash
npm install -g @anthropic-ai/claude-code   # Claude Code CLI
npm install -g @openai/codex               # Codex CLI
brew install jq                            # JSON 处理器（独立模式需要）
```

## 两种使用方式

### 方式一：在 Claude Code 内使用斜杠命令（推荐）

在任何 Claude Code 会话中直接使用 `/loopwise`，只需复制命令文件即可：

```bash
# 安装所有斜杠命令（一次性设置）
git clone https://github.com/haohappy/loopwise.git
cp loopwise/.claude/commands/loopwise*.md ~/.claude/commands/
```

安装后有三个命令可用：`/loopwise`、`/loopwise-gate`、`/loopwise-status`。

然后在 Claude Code 会话中：

```
# 审查已有文件（最常用）
> /loopwise plan --file docs/plan.md
> /loopwise code --file src/auth.ts

# 对抗性审查 — 怀疑者视角，深度审查
> /loopwise plan --file docs/plan.md --adversarial
> /loopwise code --file src/auth.ts --adversarial 重点关注认证和数据隔离

# 后台审查 — 不阻塞，稍后查看结果
> /loopwise plan --file docs/big-plan.md --background
> /loopwise-status

# 提交前快速 diff 审查
> /loopwise-gate
> /loopwise-gate 重点关注输入校验

# 从 prompt 生成并审查
> /loopwise plan Design a REST API for user management with JWT auth
> /loopwise code Implement a rate limiter middleware for Express

# 审查当前对话中刚写的内容（不传参数）
> /loopwise plan
> /loopwise code
```

### 三个斜杠命令

| 命令 | 用途 |
|------|------|
| `/loopwise` | 完整 review 循环，支持 `--file`、`--adversarial`、`--background`、`--max-rounds`、`--model`、`--force` |
| `/loopwise-gate` | 提交前快速 diff 审查，输出 WARNING/OK |
| `/loopwise-status` | 查看后台 review 任务状态 |

### v2 新功能

- **结构化 JSON 输出** — Codex 返回带 severity、confidence、recommendation 的结构化反馈
- **对抗性模式** (`--adversarial`) — 怀疑者视角审查，检查 7 个攻击面：认证、数据、韧性、并发、边界、演进、可观测性
- **Review Gate** (`/loopwise-gate`) — 提交前快速审查 git diff
- **后台执行** (`--background`) — 不阻塞当前工作，用 `/loopwise-status` 查看进度
- **验证后再修改** — Claude Code 独立验证每个 Codex 发现后才修改
- **Disposition 追踪** — 每个发现标记为 verified、dismissed 或 unverified_fix

**截图：review 循环运行实况**

<img src="assets/screenshot1.png" alt="Loopwise Round 1 - Codex 审查与 Claude Code 修改">

<img src="assets/screenshot2.png" alt="Loopwise Round 2 - 继续审查与修复">

### 方式二：独立 shell 命令

从终端作为独立进程运行：

```bash
# 安装
git clone https://github.com/haohappy/loopwise.git
cd loopwise
./install.sh            # 安装到 /usr/local/bin
# 或: ./install.sh ~/bin

# 使用
loopwise plan "构建一个带 JWT 认证的用户管理 REST API"
loopwise code "实现一个 Express 限流中间件"
loopwise plan --file docs/plan.md
loopwise code --file src/auth.ts "重构为使用 passport.js"
loopwise plan --max-rounds 10 --verbose "设计一个实时通知系统"
```

## 默认模型

- **Claude Code**：Claude Opus 4.6（用于计划/代码生成和修改）
- **Codex**：GPT-5.4（用于审查）

## 配置

通过 CLI 参数或环境变量配置：

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--max-rounds` | `LOOPWISE_MAX_ROUNDS` | *（无限制）* | 最大 review 轮数（0 = 不限） |
| `--claude-model` | `LOOPWISE_CLAUDE_MODEL` | Claude Opus 4.6 | Claude 生成模型 |
| `--codex-model` | `LOOPWISE_CODEX_MODEL` | GPT-5.4 | Codex 审查模型 |
| `--output-dir` | `LOOPWISE_OUTPUT_DIR` | .loopwise | 会话产物目录 |
| `--timeout` | `LOOPWISE_TIMEOUT` | 300 | 每次 CLI 调用超时（秒） |
| `--verbose` | `LOOPWISE_VERBOSE` | false | 显示调试输出 |

### `/loopwise` 自动授权权限

在 Claude Code 中运行 `/loopwise` 时，可能会被要求确认每个 Bash 命令。将以下内容添加到 `~/.claude/settings.json` 可跳过这些确认：

```json
{
  "permissions": {
    "allow": [
      "Bash(cat /tmp/loopwise*)",
      "Bash(cat */tmp/loopwise*)",
      "Bash(rm -f /tmp/loopwise*)",
      "Bash(shasum *)",
      "Bash(mkdir -p .loopwise*)",
      "Bash(*codex exec*)",
      "Bash(cd *codex exec*)",
      "Write(/tmp/loopwise*)",
      "Read(/tmp/loopwise*)"
    ]
  }
}
```

这些规则允许 `/loopwise` 使用的特定工具调用。如果你已有其他权限规则，将这些条目合并到现有的 `permissions.allow` 数组中即可。

## 产物输出

每次会话在 `.loopwise/` 下创建一个带时间戳的目录：

```
.loopwise/
  20260329_143022_12345/
    round_1_claude.md           # 初始生成
    round_2_codex_review.md     # 第一轮审查
    round_2_claude_revised.md   # 第一轮修改
    round_3_codex_review.md     # 第二轮审查
    final.md                    # 最终版本
    status.txt                  # APPROVED 或 MAX_ROUNDS_REACHED
```

## Review 报告

评审循环结束后，Loopwise 会在当前工作目录自动生成结构化报告：

- Plan 模式：`PLAN_REVIEW_REPORT_DD-MM-YYYY.md`
- Code 模式：`CODE_REVIEW_REPORT_DD-MM-YYYY.md`

例如：`CODE_REVIEW_REPORT_30-03-2026.md`。同一天多次评审会自动加序号：`CODE_REVIEW_REPORT_30-03-2026_2.md`。

报告包含：
- 评审元数据（模式、状态、总轮数、日期、使用的模型）
- 逐轮摘要：Codex 的关键反馈 + Claude Code 的修改内容
- 最终结果（已通过或剩余问题）

示例：

```markdown
# Codex Plan Review Report

- **Mode**: plan
- **Status**: APPROVED
- **Total rounds**: 3
- **Date**: 2026-03-30 14:20
- **Models**: Claude Code (claude-opus-4-6) ↔ Codex (gpt-5.4)
- **Input**: --file docs/REFACTORING_PLAN.md

## 逐轮摘要

### Round 1: Codex review #1
- **Verdict**: FEEDBACK
- **Key feedback**:
  - 缺少 token 过期的错误处理
  - 没有限流策略
- **Revision**: Claude Code 修复了反馈：
  - 添加了 JWT refresh token 流程
  - 添加了限流章节

### Round 2: Codex review #2
- **Verdict**: APPROVED
- **Comments**: 没有更多问题

## Final result
计划在 3 轮后通过审查。
```

## Review 历史

使用 `--file` 审查文件时，工具会基于文件内容的 SHA-256 哈希自动追踪 review 历史（`.loopwise/history.json`）：

- **文件未变 + 已通过** → 自动跳过，提示"文件未修改，之前已通过审查"
- **文件未变 + 上次未通过** → 提示可以继续上次的反馈，或重新开始
- **文件已变** → 正常开始新一轮 review
- **强制重新审查**：使用 `--force` 跳过历史检查

## 最佳实践

### 文件组织

把计划写成 Markdown 文件放到项目 `docs/` 目录。好处：
- 可以版本控制
- 每轮修改有 git diff
- 团队可以看到演进过程

### 模型选择

- **计划审查：** 用 `gpt-5.4`（默认，推理能力强）
- **代码审查：** 也用 `gpt-5.4`（能结合项目上下文）
- 切换模型：`/loopwise plan --model o3 --file docs/plan.md`

### 验证后再修改

Codex 可能会产生幻觉或误读上下文。Claude Code 会独立验证每个反馈点——检查问题是否真实存在。不存在的反馈会在报告中标注为已驳回，而不是盲目执行。

### 每轮只改 Codex 指出的问题

不要过度修改。每轮只针对已验证的反馈点改，否则：
- 可能引入新问题
- 难以追踪改了什么
- Codex 下一轮可能因为上下文变化给出不相关反馈

### 每轮提交

每轮 Codex 反馈修复后都 commit + push：

```bash
git commit -m "Refactoring plan v3: fix Codex round 2 feedback (7 issues)"
```

这样每个版本都有记录，团队可以 review 演进过程。

### 知道何时停止

- **APPROVED** — Codex 通过，可以开工
- **Round 3-4 反馈进入操作细节** — 架构已稳，可以开工
- **Round 5 仍有架构级问题** — 可能需要重新思考方向

> 对于复杂系统，不要追求 APPROVED——追求的是"反馈层级从架构降到实现"。

### 审查严格度

编辑 `loopwise.sh` 中的 review prompt 来调节 Codex 的审查标准。可以更严格（"只有完全没有问题才能通过"）或更宽松（"整体方案合理即可通过"）。

### 成本控制

使用 `LOOPWISE_CODEX_MODEL=gpt-4.1-mini` 或 `LOOPWISE_MAX_ROUNDS=3` 来降低实验阶段的 API 开销。

## 许可证

MIT
