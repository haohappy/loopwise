# Loopwise: Automated Review Tutorial

> Based on a real-world plan review process
>
> Tools: Claude Code `/loopwise` slash command + OpenAI Codex CLI (GPT-5.4)


---

## Basic Usage

### 1 Review an existing file (most common)

According to our experience, it's always a good practice to ask Claude to save its plan into a .md file first, whether it's a dev plan, refactoring plan, or anything else. Then have Codex review that file with --file before moving forward.

```
/loopwise plan --file docs/REFACTORING_PLAN.md
```

- `plan` — Review mode (plan or code)
- `--file` — Path to the file to review

### 2 Review what you just wrote in the conversation

```
/loopwise plan
```

Without `--file`, it automatically reviews the most recent plan or code produced in the current conversation.

### 3 Generate from a prompt, then review

```
/loopwise plan Design a REST API for user management with JWT auth
```

Claude Code generates the plan first, then automatically sends it to Codex for review.

### 4 Review code

```
/loopwise code --file src/auth.ts
```

Code mode evaluates: correctness, performance, error handling, readability, security, and test coverage.

### 5 Optional flags

```
/loopwise plan --file docs/plan.md --max-rounds 5      # Limit to 5 rounds
/loopwise code --file src/auth.ts --model o3            # Specify Codex model
/loopwise plan --file docs/plan.md --force              # Skip history check, force re-review
```

---

## Real-World Case Study

Below is the full process of using Loopwise to review a payment architecture refactoring plan.

### Round 1: Foundational architecture issues

**Command:**
```
/loopwise plan --file docs/REFACTORING_PLAN.md
```

**Codex feedback (5 issues):**

| # | Severity | Issue |
|---|----------|-------|
| 1 | HIGH | Phase 1 only refactored outbound; webhook/deposit endpoints still coupled |
| 2 | HIGH | Wallet unique key design flawed; multiple assets on the same chain cannot coexist |
| 3 | HIGH | Chain enum hardcoded; missing migration strategy |
| 4 | MEDIUM | Backfill script missing filter conditions |
| 5 | MEDIUM | Dual-write has no crash recovery mechanism |

**What changed:** Added abstraction layers, fixed model design, added migration strategy, switched to DB transactions.

> **Key insight:** Round 1 issues are the most valuable — they are architecture-level defects. Catching them in the implementation phase would cost 10x more to fix.

### Round 2: Completeness and security

**Codex found 7 issues**, including missed call sites, race conditions, and unsafe dispatch inside transactions.

> **Key insight:** Codex discovered call sites that Claude missed. A single model rarely achieves full coverage.

### Round 3: Operations and deployment safety

**Codex raised 6 issues**, all at the operations level: missing indexes, missing concurrency controls, race conditions in deployment sequence.

> **Key insight:** By Round 3, all architecture issues were resolved. Feedback shifted to "deployment safety" — a signal that the plan is approaching production readiness.

### Rounds 4-5: Consistency and implementation details

Later rounds focused on naming inconsistencies, edge cases, idempotency semantics, and other implementation-level details.

---

## 5. The Pattern of Review Rounds

| Round | Issue Level | Typical Issues |
|-------|------------|----------------|
| **Round 1** | Architecture | Missing abstractions, wrong coupling direction, model design flaws |
| **Round 2** | Completeness | Missed call sites, unconsidered paths, security gaps |
| **Round 3** | Operations | Deployment sequence, indexes, concurrency, monitoring |
| **Round 4** | Consistency | Internal inconsistencies, edge cases, naming conflicts |
| **Round 5** | Implementation | Idempotency edge cases, retry semantics, state ordering, recovery paths |

> **Conclusion: The first 3 rounds deliver the most value.** If you can only run 3 rounds, run 3 rounds. Later rounds have diminishing returns but are still helpful.

---

## 6. Output Artifacts

After each review session, Loopwise automatically generates:

### Review Report

Filename depends on the mode:
- Plan mode: `PLAN_REVIEW_REPORT.md`
- Code mode: `CODE_REVIEW_REPORT.md`

The report contains a round-by-round summary of feedback and fixes for easy retrospection.

### Review History

When using `--file` mode, Loopwise records review history in `.loopwise/history.json` (based on file content SHA-256 hash). When reviewing the same file again:

- **Unchanged + previously approved** — Automatically skipped with a notice
- **Unchanged + previously incomplete** — Offers to resume with prior feedback
- **Content changed** — Starts a fresh review
- **`--force`** — Skips history check, forces a new review

### Standalone command artifacts

When using the `loopwise` standalone command, each session creates a timestamped directory under `.loopwise/`:

```
.loopwise/
  20260329_143022_12345/
    round_1_claude.md           # Initial generation
    round_2_codex_review.md     # First review
    round_2_claude_revised.md   # First revision
    round_3_codex_review.md     # Second review
    final.md                    # Final version
    status.txt                  # APPROVED or MAX_ROUNDS_REACHED
```

---

## 7. Best Practices

### 7.1 File organization

Write plans as Markdown files in your project's `docs/` directory. Benefits:
- Version controlled
- Each round produces a git diff
- Team can see the evolution

### 7.2 Model selection

- **Plan review:** Use `gpt-5.4` (default, strong reasoning)
- **Code review:** Also use `gpt-5.4` (understands project context)
- Switch models: `/loopwise plan --model o3 --file docs/plan.md`

### 7.3 Only fix what Codex flagged

Don't over-revise. Only address the specific feedback points each round, otherwise:
- You may introduce new issues
- It becomes hard to track what changed
- Codex may give unrelated feedback next round due to context shift

### 7.4 Commit after each round

Commit and push after fixing each round of feedback:

```bash
git commit -m "Refactoring plan v3: fix Codex round 2 feedback (7 issues)"
```

This creates a clear record and lets your team review the evolution.

### 7.5 Know when to stop

- **APPROVED** — Codex approved, ready to implement
- **Round 3-4 feedback is operational details** — Architecture is stable, ready to implement
- **Round 5 still has architecture-level issues** — May need to rethink the approach

> For complex systems, don't chase APPROVED — what matters is that feedback shifts from architecture-level to implementation-level.

---

## 8. FAQ

### Q: Codex keeps giving feedback and never says APPROVED. Will it ever pass?

Codex is instructed to "not say APPROVED if you have any suggestions." For complex system plans, it will keep finding detailed issues. Focus on the *level* of feedback shifting downward, not on the APPROVED signal itself.

### Q: What if Codex's feedback conflicts with Claude's judgment?

Use your own engineering judgment. Codex feedback is a suggestion, not a mandate. Some feedback may be over-engineering — you can note it but defer implementation.

### Q: What's the difference between plan and code mode?

- `plan` mode evaluates: completeness, feasibility, edge cases, architecture, security
- `code` mode evaluates: correctness, performance, error handling, readability, security, testing

### Q: What if I get a "model not supported" error?

Switch models. `gpt-5.4` has the best compatibility and is the default.

### Q: Will reviewing the same unchanged file waste tokens?

No. Loopwise detects unchanged files via content hash. If the file hasn't changed and was previously approved, the review is skipped. Use `--force` to override.

---

## 9. Quick Reference

```bash
# Review an existing plan
/loopwise plan --file docs/my-plan.md

# Review an existing code file
/loopwise code --file src/auth.ts

# Generate a plan and review it
/loopwise plan Design a caching layer for the API

# Generate code and review it
/loopwise code Implement rate limiter middleware

# Review what you just wrote in the conversation
/loopwise plan
/loopwise code

# Limit rounds
/loopwise plan --file docs/plan.md --max-rounds 3

# Specify model
/loopwise code --file src/auth.ts --model o3

# Force re-review
/loopwise plan --file docs/plan.md --force
```

---

## 10. Sample Review Results

| Metric | Value |
|--------|-------|
| Review rounds | 5 |
| Total issues found | 36 |
| Fixed | 26 (rounds 1-4) |
| Deferred to implementation | 10 (round 5) |
| Document growth | 942 lines to 1600+ lines |
| Appendices added | 11 |
| Codex final assessment | "direction is good...sound choices" |

> The value of two AIs cross-reviewing: Claude excels at generating comprehensive plans, Codex excels at spotting omissions and edge cases. Together, their coverage far exceeds either model alone.
