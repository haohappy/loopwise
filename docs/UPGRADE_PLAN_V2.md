# Loopwise v2 升级计划：借鉴 codex-plugin-cc

## Context

OpenAI 官方发布了 `codex-plugin-cc`（Codex Plugin for Claude Code），实现了 Claude Code ↔ Codex 的集成。分析其代码仓库后，发现若干值得 Loopwise 借鉴的功能。本计划筛选出**高价值、可落地**的功能，分优先级实施。

## 对比分析：codex-plugin-cc vs Loopwise

| 功能 | codex-plugin-cc | Loopwise 现状 | 值得借鉴？ |
|------|----------------|--------------|-----------|
| 对抗性审查模式 | 有（adversarial-review） | 无 | **是 - 高价值** |
| 结构化输出 Schema | 有（JSON: verdict/findings/severity/confidence） | 无（自由文本） | **是 - 高价值** |
| 后台运行 | 有（background jobs + status） | 无 | **是 - 中等价值** |
| 任务委托/rescue | 有 | 无（非核心） | 否 - 偏离 review 定位 |
| Stop Review Gate | 有（自动拦截有问题的代码） | 无 | **是 - 高价值** |
| GPT-5.4 提示词最佳实践 | 有（SKILL.md） | 无 | **是 - 中等价值** |
| App Server Broker 架构 | 有（三进程模型） | 无 | 否 - 过度工程化 |
| Job Tracking 持久化 | 有（jobs目录 + state.json） | 简单的 history.json | 部分借鉴 |
| Resume 会话 | 有（codex resume session-id） | 有（claude --resume） | 已有 |
| Severity + Confidence 评分 | 有 | 无 | **是 - 高价值** |

## 升级计划（按优先级排序）

---

### Phase 1: 结构化审查输出（P0 - 最高优先级）

**目标**：让 Codex 返回结构化 JSON 而非自由文本，使反馈可解析、可排序、可统计。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 修改 review prompt，要求 Codex 返回 JSON
- `.claude/commands/loopwise.md` — 仓库副本同步

**具体改动**：

1. 在 Step 2b 的 review prompt 末尾加入输出格式要求：
```
Respond in JSON format:
{
  "verdict": "approve" | "needs-attention",
  "summary": "one-line assessment",
  "findings": [
    {
      "severity": "critical" | "high" | "medium" | "low",
      "title": "short title",
      "body": "detailed explanation",
      "file": "file path (if applicable)",
      "line_start": number,
      "confidence": 0.0-1.0,
      "recommendation": "how to fix"
    }
  ],
  "next_steps": ["actionable item 1", "actionable item 2"]
}
```

2. 在 Step 3（Check approval）中，解析 JSON 的 `verdict` 字段而非检查 "APPROVED" 文本

3. 在 Step 4（Revise）中，按 severity 排序显示反馈给用户，用 confidence 过滤低置信度的建议

4. 在 Step 6（Review Report）中，用结构化数据生成更精确的报告（包含 severity 分布、confidence 统计）

**验证**：运行 `/loopwise plan --file docs/TUTORIAL.md`，检查 Codex 返回结构化 JSON 且被正确解析。

---

### Phase 2: 对抗性审查模式（P0）

**目标**：新增 `--adversarial` 标志，启用 Codex 的对抗性审查，从怀疑者角度挑战设计决策。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 新增 `--adversarial` flag 解析和对应的 prompt
- `.claude/commands/loopwise.md` — 仓库副本同步

**具体改动**：

1. Step 0 解析新增 `adversarial` flag

2. 新增对抗性 review prompt（借鉴 codex-plugin-cc 的 `adversarial-review.md`）：
```
Default to skepticism.
Assume the change can fail in subtle, high-cost, or user-visible ways
until the evidence says otherwise.

Attack surface (check in order):
1. Auth/Trust: permissions, tenant isolation, boundaries
2. Data: loss, corruption, duplication, irreversibility
3. Resilience: rollback, retries, partial failure, idempotency
4. Concurrency: race conditions, ordering, stale state
5. Edge Cases: empty-state, null, timeout, degraded dependencies
6. Evolution: version skew, schema drift, migrations
7. Observability: gaps that hide failure

Report only material findings. No style or naming feedback.
Each finding must answer: What fails? Why? Impact? Fix?
```

3. 对抗性模式下审查标准更高，`verdict: approve` 仅在无实质性风险时给出

**用法**：
```
/loopwise plan --file docs/plan.md --adversarial
/loopwise code --file src/auth.ts --adversarial focus on auth and data isolation
```

**验证**：对比同一文件的普通 review 和 adversarial review，后者应发现更多深层问题。

---

### Phase 3: Review Gate — 自动拦截（P1）

**目标**：在 Claude Code 完成代码修改后，自动触发 Codex 审查。如果发现严重问题，阻止继续。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 新增 `/loopwise gate` 子命令说明
- `~/.claude/commands/loopwise-gate.md` — 新建独立命令（更简洁）

**具体改动**：

1. 创建 `loopwise-gate.md` 斜杠命令：
   - 自动获取当前 git diff（未暂存的改动）
   - 将 diff 发送给 Codex 做快速审查
   - 如果有 critical/high severity 发现，输出警告并建议修复
   - 如果全部是 medium/low，提示用户可以继续

2. 可以手动调用 `/loopwise-gate`，也可以在 `/loopwise` review 结束后自动建议

**用法**：
```
# Claude Code 刚改完代码后
/loopwise-gate
# → "2 critical issues found in your changes. Fix before committing."
# → "All clear. Changes look safe to commit."
```

**验证**：故意引入一个安全漏洞，运行 `/loopwise-gate`，确认被拦截。

---

### Phase 4: GPT-5.4 提示词优化（P1）

**目标**：将 codex-plugin-cc 的 GPT-5.4 提示词最佳实践应用到 Loopwise 的 review prompt 中。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 优化 prompt 结构

**具体改动**：

1. 用 XML 标签结构化 prompt（GPT-5.4 对此响应更好）：
```xml
<task>Review this {plan/code} for production readiness</task>
<output_contract>Respond in JSON: {schema}</output_contract>
<grounding>Ground every claim in the provided content. Mark inferences.</grounding>
<follow_through>Complete the full review. Do not stop early.</follow_through>
```

2. 添加 `completeness_contract`：防止 Codex 提前停止审查
3. 添加 `dig_deeper_nudge`：发现初步问题后检查二阶故障

**验证**：对比优化前后的 review 质量（覆盖度、precision）。

---

### Phase 5: 后台运行支持（P2）

**目标**：支持 `/loopwise plan --file docs/plan.md --background`，review 在后台执行。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 新增 `--background` flag
- `~/.claude/commands/loopwise-status.md` — 新建状态查询命令

**具体改动**：

1. `--background` 模式下：
   - Codex 调用使用 Bash 的 `run_in_background: true`
   - 告知用户 "Review started in background, use /loopwise-status to check"

2. 新建 `/loopwise-status` 命令：
   - 读取 `.loopwise/history.json` 中的进行中任务
   - 显示当前状态（running/completed/failed）

3. Review 完成后自动保存结果到 `.loopwise/` 目录

**用法**：
```
/loopwise plan --file docs/plan.md --background
# → "Review started in background."

/loopwise-status
# → "1 review running (plan, docs/plan.md, started 2 min ago)"

# 完成后自动通知
```

**验证**：启动后台 review，用 `/loopwise-status` 查看状态，确认完成后结果可获取。

---

### Phase 6: Review Report 增强（P2）

**目标**：利用结构化输出生成更丰富的报告。

**修改文件**：
- `~/.claude/commands/loopwise.md` — 增强 Step 6 报告格式

**具体改动**：

1. 在报告中添加统计摘要：
```markdown
## Statistics
- Total findings: 12
- By severity: 2 critical, 4 high, 3 medium, 3 low
- Average confidence: 0.87
- Dismissed (not verified): 2
```

2. 添加 severity 分布的文本图表：
```
Critical  ██ 2
High      ████ 4
Medium    ███ 3
Low       ███ 3
```

3. 每个 finding 包含文件位置和置信度

**验证**：运行一次完整 review，检查报告中包含统计摘要和 severity 分布。

---

## 实施顺序

```
Phase 1 (结构化输出)  ──→  Phase 2 (对抗性模式)  ──→  Phase 3 (Review Gate)
         │                                                    │
         └──→  Phase 4 (提示词优化，可与 Phase 2 并行) ──────┘
                                                              │
                                                    Phase 5 (后台运行)
                                                              │
                                                    Phase 6 (报告增强)
```

- **Phase 1 + 2**：立即开始，它们是最高价值的改进
- **Phase 3 + 4**：Phase 1 完成后开始
- **Phase 5 + 6**：锦上添花，时间允许再做

## 不采纳的功能

| 功能 | 不采纳原因 |
|------|-----------|
| App Server Broker | 三进程模型过于复杂，Loopwise 的简单管道模式已够用 |
| Rescue/任务委托 | 偏离 Loopwise 的 review 定位，用户已有 Claude Code 做开发 |
| Session lifecycle hooks | 需要 Claude Code plugin 机制，Loopwise 是 skill 不是 plugin |
| Job tracking 持久化 | 现有 history.json 已满足需求，无需完整的 job 系统 |
