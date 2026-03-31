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

## 产品范围声明

**v2 仅升级 `/loopwise` 斜杠命令。`loopwise.sh` 独立脚本保持现状不做改动。** 文档（README、Tutorial）中会明确标注哪些功能仅限斜杠命令可用。如果未来需要同步升级 `loopwise.sh`，将作为独立的 Phase 7 处理。

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
  "schema_version": 1,
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

**Required top-level fields**: `schema_version`, `verdict`, `summary`, `findings`.
**Optional top-level fields**: `next_steps`.

**Verdict 枚举值**（精确定义）：
- `approve` — 无实质性问题，可以实施
- `needs_attention` — 有需要处理的问题
- `degraded` — 工具/解析错误导致审查不完整

**findings 可以为空数组** `[]`（当 verdict 为 approve 时合法）。

**schema_version 策略**：v2 期间固定为 `1`。解析时如果 `schema_version` 缺失或为未知值，verdict 强制设为 `degraded`，走 fallback 路径，绝不视为 approve。
**Required per-finding fields**: `severity`, `title`, `body`, `confidence`, `recommendation`.
**Optional per-finding fields**: `file`, `line_start`.

Claude Code 在验证后会为每个 finding 添加 `disposition` 字段：
- `verified` — 已确认问题存在并修复
- `dismissed` — 经验证问题不存在，附原因
- `unverified_fix` — 不确定但倾向修复

**Disposition 缺失时的行为**：如果 report 中某些 findings 没有 disposition（例如 max-rounds 退出时最后一轮未验证的 findings），Phase 6 统计中将它们计入 "unprocessed" 类别，不计入 dismissed 或 verified。

2. 在 Step 3（Check approval）中，解析 JSON 的 `verdict` 字段，三路分支：
   - `approve` → 循环结束，生成报告，状态为 APPROVED
   - `needs_attention` → 进入 Step 4 验证和修改
   - `degraded` → **立即终止循环**，不进入 Step 4 修改。生成报告（状态为 DEGRADED），记录原因。在后台模式下 job 状态设为 `failed`（error 字段记录降级原因）。**绝不基于 degraded payload 做任何代码/计划修改。**

3. **JSON 解析容错策略**：
   - 如果 Codex 返回的不是合法 JSON：提取文本中的 JSON 块（```json...``` 或 {…} 边界）再解析
   - 如果仍然失败：重试一次，prompt 追加 "You MUST respond with valid JSON only, no other text"
   - 如果重试仍失败：将原始文本构造为以下固定 payload：
     ```json
     {
       "verdict": "needs-attention",
       "summary": "Codex returned unstructured text (JSON parse failed)",
       "findings": [{
         "severity": "medium",
         "title": "Unstructured feedback",
         "body": "<raw Codex output>",
         "confidence": 0.5,
         "recommendation": "Review the raw feedback manually"
       }],
       "next_steps": ["Re-run review or manually inspect Codex output"]
     }
     ```
   - 绝不将解析失败静默处理为 approve

4. 在 Step 4（Revise）中，按 severity 排序显示反馈给用户。**Confidence 仅用于显示和排序，不用于过滤**。所有 critical/high findings 无论 confidence 高低都必须处理。

5. 在 Step 6（Review Report）中，用结构化数据生成更精确的报告（包含 severity 分布、confidence 统计）

**验证**：
- 正常 case：运行 `/loopwise plan --file docs/TUTORIAL.md`，检查 Codex 返回结构化 JSON 且被正确解析
- 异常 case：手动构造一个非 JSON 响应，验证容错逻辑正确回退
- 边界 case：零 findings 响应、缺少 optional 字段响应

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

**性质**：**建议性（advisory），非阻断性（non-blocking）。** Gate 无法真正阻止用户操作，它输出警告并建议，由用户决定是否继续。

**具体改动**：

1. 创建 `loopwise-gate.md` 斜杠命令：
   - **输入选择顺序**：staged changes (`--cached`) > unstaged changes > 可选 untracked files
   - 如果 diff 为空，提示"没有检测到改动"并退出
   - 如果不在 git 仓库中，提示错误并退出
   - 如果 diff 过大（>5000 行），**拒绝执行**并输出明确提示："Diff too large (N lines). Use `/loopwise code --file <path>` to review specific files, or split your changes into smaller commits." 不做部分审查，不静默截断。
   - 排除 vendor/generated 文件（`node_modules/`, `vendor/`, `*.min.js`, `*.lock`）
   - 将 diff + 相关文件上下文发送给 Codex 做快速审查
   - 如果有 critical/high severity 发现，输出 **WARNING** 并建议修复
   - 如果全部是 medium/low 且无解析错误，输出 **OK** 提示用户可以继续
   - 如果 Codex 调用失败、JSON 解析失败、或使用了 fallback payload，输出 **WARNING (degraded)** 并提示 "Review incomplete due to tool/parse error. Treat as unsafe."——绝不在降级模式下输出 OK

2. 可以手动调用 `/loopwise-gate`，也可以在 `/loopwise` review 结束后自动建议

**用法**：
```
# Claude Code 刚改完代码后
/loopwise-gate
# → "⚠️ WARNING: 2 critical issues found in your changes. Recommend fixing before committing."
# → "✅ OK: No critical issues. 1 medium suggestion noted. Safe to proceed."
```

**验证**：
- 故意引入一个安全漏洞，运行 `/loopwise-gate`，确认输出 WARNING
- 空 diff 场景，确认正确提示
- 非 git 目录，确认正确报错
- 大 diff (>5000行) 场景，确认建议分拆

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

1. **引入 Job 模型**（独立于 `history.json`）：
   - 存储路径：`.loopwise/jobs/<job_id>/state.json`
   - Job 状态：
     ```json
     {
       "id": "job-<timestamp>-<nonce>",
       "status": "running" | "completed" | "failed" | "stale",
       "mode": "plan" | "code",
       "file": "docs/plan.md",
       "started_at": "ISO8601",
       "updated_at": "ISO8601 (每次状态变化或每轮 review 完成时更新)",
       "ended_at": "ISO8601 (if finished)",
       "codex_session_id": "...",
       "artifacts": ["round_1_review.md", ...],
       "error": null,
       "report": "PLAN_REVIEW_REPORT_31-03-2026.md"
     }
     ```
   - **Stale 检测**：`stale` 是**派生状态（derived view）**，不持久化写入 state.json。`/loopwise-status` 在展示时计算：**仅当 `status == running`** 且 `updated_at` 距今 > 15 分钟时，显示为 stale。`completed` 和 `failed` 状态不受 stale 检测影响。如果后台 worker 最终完成，它直接写入 `completed/failed`，不存在状态转换冲突。
   - `history.json` 仅记录已完成的 review（不变），`jobs/` 管理运行中和已完成的 job

2. `--background` 模式下：
   - 创建 job 目录和 state.json（status: running）
   - Codex 调用使用 Bash 的 `run_in_background: true`
   - 告知用户 "Review started in background (job: <id>), use /loopwise-status to check"

3. 新建 `/loopwise-status` 命令：
   - 扫描 `.loopwise/jobs/` 中所有 job 的 state.json
   - 显示当前状态表（id, mode, file, status, elapsed）

4. Job 完成后更新 state.json（status: completed/failed），保存 report 路径

5. **原子写入**：所有 state.json 更新采用 write-to-temp + rename 模式。临时文件**必须在同一目录**内创建（`.loopwise/jobs/<job_id>/state.json.tmp.<nonce>`），然后 `mv` 覆盖 `state.json`，保证 rename 是同一文件系统上的原子操作。

**用法**：
```
/loopwise plan --file docs/plan.md --background
# → "Review started in background (job: job-1711871234). Use /loopwise-status to check."

/loopwise-status
# → | Job ID | Mode | File | Status | Elapsed |
#    | job-... | plan | docs/plan.md | running | 2m 15s |
```

**验证**：
- 启动后台 review，用 `/loopwise-status` 查看 running 状态
- 等待完成后，确认 status 变为 completed 且 report 可获取
- 模拟 Codex 失败，确认 status 变为 failed 且 error 有记录

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

## 安全与并发

1. **临时文件隔离**：斜杠命令的临时文件从固定路径 `/tmp/loopwise-*.md` 改为 `/tmp/loopwise-<job_id>-*.md`（每次调用生成唯一 job_id = timestamp + 4位随机数），避免同一会话内并发运行时的冲突。
2. **产物清理**：`.loopwise/jobs/` 中超过 30 天的 job 目录自动清理（在 `/loopwise-status` 执行时顺带处理）。
3. **敏感信息**：review report 中不包含完整代码，只引用文件路径和行号。`.loopwise/` 应加入 `.gitignore`（已有）。
4. **Gate 默认手动**：`/loopwise-gate` 需要用户主动调用，不会自动触发。

## 不采纳的功能

| 功能 | 不采纳原因 |
|------|-----------|
| App Server Broker | 三进程模型过于复杂，Loopwise 的简单管道模式已够用 |
| Rescue/任务委托 | 偏离 Loopwise 的 review 定位，用户已有 Claude Code 做开发 |
| Session lifecycle hooks | 需要 Claude Code plugin 机制，Loopwise 是 skill 不是 plugin |
| Job tracking 持久化 | 现有 history.json 已满足需求，无需完整的 job 系统 |
