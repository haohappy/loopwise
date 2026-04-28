# Loopwise — Automated Review Loop (v2)

Automated review loop: you (Claude Code) produce a plan or code, then Codex reviews it with structured JSON output, you verify and revise based on feedback, and the cycle repeats until Codex approves.

## Arguments

$ARGUMENTS should be in format: `<mode> [--file <path>] [--since <ref>] [flags] [prompt or instructions]`

- **mode**: `plan` or `code`
- **--file \<path\>**: Optional. Path to an existing file to use as initial content for review (skip generation).
- **--since \<ref\>**: Optional. Review code changes since a git reference. Supports commit hash (`abc1234`), relative ref (`HEAD~5`), branch name (`main`), or date (`2026-03-30`). Collects `git diff <ref>..HEAD`. Code mode only.
- **--adversarial**: Optional. Enable adversarial review mode (skeptical stance, deeper scrutiny).
- **--background**: Optional. Run the first Codex review in the background. You'll be notified when it completes. Use `/loopwise-status` to check progress.
- **--max-rounds \<n\>**: Optional. Limit review rounds. Default: no limit.
- **--model \<model\>**: Optional. Override Codex model. Default: uses Codex CLI's configured default (from `~/.codex/config.toml`).
- **--force**: Optional. Bypass review history check.
- **prompt**: What to generate or review. If none of `--file`, `--since`, or prompt are provided, review the work you just produced in this conversation.

Examples:
```
/loopwise plan --file docs/plan.md
/loopwise code --file src/auth.ts
/loopwise plan --file docs/plan.md --adversarial
/loopwise code --file src/auth.ts --adversarial focus on auth and data isolation
/loopwise plan Design a REST API for user management with JWT auth
/loopwise code --since HEAD~5
/loopwise code --since main
/loopwise code --since 2026-03-30
/loopwise code --since abc1234 --adversarial
/loopwise plan --file docs/plan.md --background
/loopwise plan
/loopwise code
```

## Instructions

You are now entering an automated review loop with Codex. Follow these steps precisely:

### Step 0: Parse arguments

Extract from $ARGUMENTS:
1. `mode` — first word: "plan" or "code"
2. `file_path` — if `--file <path>` present, extract and remove
3. `since_ref` — if `--since <ref>` present, extract and remove. The ref can be a commit hash, relative ref (HEAD~5), branch name, or date (2026-03-30). Code mode only.
4. `adversarial` — if `--adversarial` present, set true and remove. Default: false
5. `background` — if `--background` present, set true and remove. Default: false
6. `max_rounds` — if `--max-rounds <n>` present, extract and remove. Default: no limit
7. `codex_model` — if `--model <model>` present, extract and remove. Default: empty (omit `--model` flag to use Codex CLI's configured default)
8. `force` — if `--force` present, set true and remove. Default: false
9. `prompt` — everything remaining after extracting all flags

**Validation:** `--file` and `--since` are mutually exclusive. If both are provided, tell the user and stop. `--since` is only valid in `code` mode; if used with `plan` mode, tell the user and stop.

### Step 0.5: Check review history (only when `--file` is provided)

**Skip this step entirely if `force` is true.**

If `file_path` was provided, check for a previous review of the same file with the same content:

1. Compute the file's content hash:
   ```bash
   shasum -a 256 "<file_path>" | cut -d' ' -f1
   ```

2. Check if `.loopwise/history.json` exists. If the file does not exist, treat as empty (`[]`) and proceed to step 4 (no match). If the file exists but contains malformed JSON, treat as empty (`[]`) and proceed.

3. **If a matching record exists (same file path AND same hash)**:
   - If `status` is `APPROVED`: Tell the user **"This file was already reviewed and approved on {date} ({rounds} rounds). Content is unchanged (hash: {hash:.8}). Skipping review."** and show the path to the previous report. **Stop here.**
   - If `status` is `MAX_ROUNDS_REACHED` or `DEGRADED`: Tell the user about the previous review and ask if they want to resume or start fresh.

4. **If no matching record**: proceed normally.

### Step 1: Get initial content

Four cases, checked in this order:

1. **`--file` was provided**: Read the file using the Read tool. The file contents become the **initial content**.

2. **`--since` was provided** (code mode only): Collect the git diff as the initial content.

   **Step 1a:** Verify this is a git repo:
   ```bash
   git rev-parse --is-inside-work-tree
   ```
   If not a git repo, tell the user and stop.

   **Step 1b:** If `since_ref` looks like a date (YYYY-MM-DD format), convert it to a commit ref:
   ```bash
   git log --since="<date>" --reverse --format="%H" --max-count=1
   ```
   Use the returned commit hash as the actual ref. If no commits found, tell the user "No commits found since <date>" and stop.

   **Step 1c:** Get the diff (single Bash call):
   ```bash
   git diff <since_ref>..HEAD --diff-filter=d -- . ':!node_modules' ':!vendor' ':!*.min.js' ':!*.min.css' ':!*.lock'
   ```
   If the diff is empty, tell the user "No changes found between <since_ref> and HEAD" and stop.
   If the diff exceeds 5000 lines, tell the user "Diff too large (N lines). Use --file to review specific files." and stop.

   **Step 1d:** Also get the list of changed files for context:
   ```bash
   git diff <since_ref>..HEAD --name-only --diff-filter=d
   ```

   **Step 1e:** Also get the commit log for context:
   ```bash
   git log <since_ref>..HEAD --oneline
   ```

   Tell the user: **"Reviewing N commits (since <ref>), M files changed."**

   The **initial content** is the combined diff + file list + commit log. For each changed file that is NOT deleted, also Read the full current file content using the Read tool and include it after the diff. This gives Codex both the diff context and the full file to review.

   **Note:** In `--since` mode, the review loop does NOT modify code (same as `/loopwise-gate` — advisory only). Claude Code presents the findings but does not auto-fix, since the changes span multiple commits and files. The user decides what to fix.

3. **A prompt was given (no --file, no --since)**: Generate the plan or code as requested. This is your **initial content**.

4. **None of the above**: Gather the most recent plan or code you produced in this conversation.

### Step 2: Send to Codex for review

**CRITICAL RULES for this step (MUST follow — violations cause permission prompts that block automation):**
1. **NEVER use `$()` command substitution in any Bash call.**
2. **NEVER combine multiple commands with `&&`, `||`, `;`, `{ }` groups, or `for` loops into one Bash call.**
3. **Use Bash heredoc for writing temp files** (`/tmp/loopwise-*.md`) to avoid triggering security hooks that monitor the Write tool. Use Read tool for reading files.
4. **When collecting content from multiple files:** Read each with the Read tool, concatenate in memory, then write the combined result via Bash heredoc. Do NOT use shell loops or cat chains.
5. **Only FOUR Bash patterns are allowed:**
   - `cat <<'LOOPWISE_EOF' > /tmp/loopwise-content.md` or `/tmp/loopwise-prompt.md` (heredoc write — note the **single-quoted delimiter** to prevent shell expansion)
   - `cat /tmp/loopwise-prompt.md | codex exec - ...` (the single codex pipe)
   - `rm -f /tmp/loopwise-*.md` (cleanup)
   - `shasum -a 256 <file>` (hash computation)

**Step 2a:** Use a **Bash heredoc** to save the current content to `/tmp/loopwise-content.md`:
```bash
cat <<'LOOPWISE_EOF' > /tmp/loopwise-content.md
... content here ...
LOOPWISE_EOF
```

**Step 2b:** Build the review prompt and use a **Bash heredoc** to save it to `/tmp/loopwise-prompt.md`:
```bash
cat <<'LOOPWISE_EOF' > /tmp/loopwise-prompt.md
... prompt here ...
LOOPWISE_EOF
```

The prompt MUST include the JSON output contract. Use the appropriate template:

---

**If `adversarial` is false (standard review):**

For plan mode:
```
<task>Review this development plan for production readiness.</task>

<output_contract>
Respond with ONLY a JSON object (no other text). Schema:
{
  "schema_version": 1,
  "verdict": "approve" | "needs_attention",
  "summary": "one-line ship/no-ship assessment",
  "findings": [
    {
      "severity": "critical" | "high" | "medium" | "low",
      "title": "short title",
      "body": "detailed explanation",
      "file": "file path if applicable, else null",
      "line_start": null,
      "confidence": 0.0-1.0,
      "recommendation": "specific fix"
    }
  ],
  "next_steps": ["actionable item"]
}
Required: schema_version, verdict, summary, findings.
Required per finding: severity, title, body, confidence, recommendation.
findings may be empty [] if verdict is approve.
</output_contract>

<grounding>Ground every claim in the provided content. Label inferences explicitly.</grounding>

<completeness>Review the ENTIRE content. Do not stop early. Check for second-order failures after initial findings.</completeness>

Evaluate: completeness, technical feasibility, edge cases, architecture, security.

=== PLAN TO REVIEW ===
```

For code mode, replace evaluation criteria with: correctness, performance, error handling, readability, security, testing. Use `=== CODE TO REVIEW ===`.

---

**If `adversarial` is true:**

```
<task>Adversarial review: break confidence in this {plan/code}.</task>

<stance>
Default to skepticism.
Assume the change can fail in subtle, high-cost, or user-visible ways until the evidence says otherwise.
Do not give credit for good intent, partial fixes, or likely follow-up work.
</stance>

<attack_surface>
Check in priority order:
1. Auth/Trust: permissions, tenant isolation, trust boundaries
2. Data: loss, corruption, duplication, irreversibility
3. Resilience: rollback, retries, partial failure, idempotency
4. Concurrency: race conditions, ordering, stale state, re-entrancy
5. Edge Cases: empty-state, null, timeout, degraded dependencies
6. Evolution: version skew, schema drift, migrations, compatibility
7. Observability: gaps that hide failure or make recovery harder
</attack_surface>

<output_contract>
Respond with ONLY a JSON object (no other text). Schema:
{
  "schema_version": 1,
  "verdict": "approve" | "needs_attention",
  "summary": "one-line adversarial assessment",
  "findings": [
    {
      "severity": "critical" | "high" | "medium" | "low",
      "title": "short title",
      "body": "What fails? Why? Impact?",
      "file": "file path if applicable, else null",
      "line_start": null,
      "confidence": 0.0-1.0,
      "recommendation": "specific fix"
    }
  ],
  "next_steps": ["actionable item"]
}
Required: schema_version, verdict, summary, findings.
Required per finding: severity, title, body, confidence, recommendation.
Report only material findings. No style or naming feedback.
Use "approve" only when no substantive risk remains.
</output_contract>

<grounding>Ground every claim in the provided content. Label inferences explicitly.</grounding>

<completeness>Complete the full adversarial review. Do not stop early. After initial findings, check for second-order failures.</completeness>
```

If the user provided additional focus text after `--adversarial`, prepend it:
```
<user_focus>User wants special attention on: {focus text}</user_focus>
```

---

Append the full content to review at the end of the prompt file (after `=== PLAN/CODE TO REVIEW ===`).

**Step 2c:** Call Codex with a single simple Bash command.

**If `background` is false (default — foreground):**
```bash
cat /tmp/loopwise-prompt.md | codex exec - [--model <codex_model>] --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-output.md ```

**Note:** Only include `--model <codex_model>` if the user explicitly passed `--model`. If `codex_model` is empty, omit the flag entirely so Codex uses its configured default from `~/.codex/config.toml`.

**If `background` is true:**
Only the FIRST Codex call runs in background. Tell the user: **"Review started in background. You'll be notified when it completes. Use `/loopwise-status` to check progress."**

Run the Codex call using Bash with `run_in_background: true`:
```bash
cat /tmp/loopwise-prompt.md | codex exec - [--model <codex_model>] --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-output.md ```

Before launching the background call, create a job record:
```bash
mkdir -p .loopwise/jobs
```
Generate a unique job ID from the current timestamp (e.g., `job-20260331-163000`). Then use the **Write** tool to create `.loopwise/jobs/<job_id>.json`:
```json
{
  "status": "running",
  "mode": "<mode>",
  "file": "<file_path or null>",
  "adversarial": <true/false>,
  "started_at": "<ISO8601>",
  "updated_at": "<ISO8601>",
  "model": "<codex_model>",
  "output_file": "/tmp/loopwise-output.md",
  "prompt_file": "/tmp/loopwise-prompt.md"
}
```

After the background command completes (you will be notified), continue with Step 2d as normal. When done, update the job record status to `completed` or `failed`.

**Then stop here for background mode.** Do NOT enter the revision loop. Background mode only does a single Codex review pass and saves the result. The user can then review the output and decide whether to run a full foreground loop.

**Step 2d:** Use the **Read** tool to read `/tmp/loopwise-output.md`.

**Step 2e:** Clean up:
```bash
rm -f /tmp/loopwise-content.md /tmp/loopwise-prompt.md /tmp/loopwise-output.md
```

### Step 3: Parse and check verdict

Parse the Codex output as JSON. Apply this fallback chain:

1. **Try direct JSON parse** of the full output
2. **Extract JSON block** if wrapped in markdown fences (```json...```) or find the outermost `{...}`
3. **Retry once**: if parse fails, re-run Step 2 with the same content but append to the prompt: "You MUST respond with valid JSON only, no markdown fences, no other text."
4. **Synthesize degraded payload** if retry also fails. Check the Bash tool's stderr output for error context to include in the degraded report:
   ```json
   {
     "schema_version": 1,
     "verdict": "degraded",
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

After parsing, validate `schema_version`. If missing or != 1, force `verdict` to `degraded`.

**Three-way verdict branch:**
- **`approve`** → Loop ends. Go to Step 6 (report). Status: APPROVED.
- **`needs_attention`** → Go to Step 4 (verify and revise).
- **`degraded`** → **Loop terminates immediately.** Do NOT revise. Go to Step 6 (report). Status: DEGRADED. Never make code/plan changes based on a degraded payload.

### Step 4: Verify and revise based on findings

Show the user a summary of Codex's findings sorted by severity (critical first).

For EACH finding, **independently verify before acting**:

1. **Read the relevant section** of the content. Check whether the issue actually exists.
2. If **verified** — fix it. Set finding disposition to `verified`.
3. If the issue **does not exist** (hallucination/misread) — skip it. Set disposition to `dismissed` with a brief reason.
4. If **uncertain** — do NOT auto-fix. Flag it for the user: show the finding and ask if they want it fixed. Set disposition to `deferred` if the user declines, or `verified` if they confirm.

**Confidence is for display/ranking only. NEVER suppress critical or high findings based on confidence.**

Do NOT blindly apply all feedback. Your job is to be the engineer who validates before changing.

The revised version becomes the new current content.

### Step 5: Loop

Go back to Step 2 with the revised content. Repeat until:
- Verdict is `approve`, OR
- Verdict is `degraded` (terminates immediately), OR
- `max_rounds` reached — user-specified via `--max-rounds`, or **hard cap of 20 rounds** (whichever is lower). This prevents unbounded loops even if the user doesn't set a limit.

### Step 6: Write Review Report

Write a report to the current working directory. Filename: `{MODE}_REVIEW_REPORT_DD-MM-YYYY.md` (e.g., `PLAN_REVIEW_REPORT_31-03-2026.md`). If file exists, append counter: `_2.md`, `_3.md`.

Report format:

```markdown
# Codex {Plan/Code} Review Report

- **Mode**: plan / code
- **Adversarial**: yes / no
- **Status**: APPROVED / MAX_ROUNDS_REACHED / DEGRADED
- **Total rounds**: N
- **Date**: YYYY-MM-DD HH:MM
- **Models**: Claude Code (claude-opus-4-6) ↔ Codex (<model used, or "default" if --model was not specified>)
- **Input**: (prompt text, or file path if --file was used)

## Statistics
- Total findings: N
- By severity: X critical, X high, X medium, X low
- Average confidence: 0.XX
- Disposition: X verified, X dismissed, X unverified_fix, X unprocessed

```
Critical  ██ X
High      ████ X
Medium    ███ X
Low       ███ X
```

## Round-by-round summary

### Round 1: Codex review #1
- **Verdict**: needs_attention
- **Findings** (N issues):
  - [critical] Title (confidence: 0.95) — **verified**, fixed
  - [high] Title (confidence: 0.88) — **dismissed**: reason
  - [medium] Title (confidence: 0.72) — **verified**, fixed
- **Revision summary**:
  - Changed X to Y
  - Added Z

### Round N: Codex review #N
- **Verdict**: approve
- **Comments**: (final Codex assessment)

## Final result
(Whether approved, max rounds reached with remaining issues, or degraded with reason.)
```

After writing, tell the user the exact filename.

### Step 7: Update review history (only when `--file` was provided)

1. Compute final file hash
2. Read `.loopwise/history.json` (or `[]`)
3. Remove existing record for same file path
4. Append new record:
   ```json
   {
     "file": "<file_path>",
     "hash": "<final_hash>",
     "status": "APPROVED" | "MAX_ROUNDS_REACHED" | "DEGRADED",
     "date": "<datetime>",
     "rounds": <N>,
     "report": "<report_filename>",
     "last_feedback": "<last findings JSON if not approved, null if approved>"
   }
   ```
5. Write back to `.loopwise/history.json`

## Important rules

- **Show progress**: "Round N: Sending to Codex for review (adversarial)..." or "Round N: Sending to Codex for review..."
- **Be transparent**: Show findings summary each round (severity counts + top issues)
- **Verify before fixing**: Codex can hallucinate. Independently verify each finding. Dismiss invalid ones with reason.
- **Don't over-revise**: Only fix verified findings, don't rewrite everything
- **Confidence is display-only**: Never suppress critical/high findings based on confidence
- **Degraded = terminal**: Never revise based on degraded output
- **Adversarial mode**: When `--adversarial` is set, tell the user at the start: "Adversarial mode enabled — Codex will apply skeptical scrutiny."
