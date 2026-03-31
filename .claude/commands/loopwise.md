# Loopwise — Automated Review Loop (v2)

Automated review loop: you (Claude Code) produce a plan or code, then Codex reviews it with structured JSON output, you verify and revise based on feedback, and the cycle repeats until Codex approves.

## Arguments

$ARGUMENTS should be in format: `<mode> [--file <path>] [flags] [prompt or instructions]`

- **mode**: `plan` or `code`
- **--file \<path\>**: Optional. Path to an existing file to use as initial content for review (skip generation).
- **--adversarial**: Optional. Enable adversarial review mode (skeptical stance, deeper scrutiny).
- **--background**: Optional. Run the first Codex review in the background. You'll be notified when it completes. Use `/loopwise-status` to check progress.
- **--max-rounds \<n\>**: Optional. Limit review rounds. Default: no limit.
- **--model \<model\>**: Optional. Codex model. Default: `gpt-5.4`.
- **--force**: Optional. Bypass review history check.
- **prompt**: What to generate or review. If both `--file` and prompt are omitted, review the work you just produced in this conversation.

Examples:
```
/loopwise plan --file docs/plan.md
/loopwise code --file src/auth.ts
/loopwise plan --file docs/plan.md --adversarial
/loopwise code --file src/auth.ts --adversarial focus on auth and data isolation
/loopwise plan Design a REST API for user management with JWT auth
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
3. `adversarial` — if `--adversarial` present, set true and remove. Default: false
4. `background` — if `--background` present, set true and remove. Default: false
5. `max_rounds` — if `--max-rounds <n>` present, extract and remove. Default: no limit
6. `codex_model` — if `--model <model>` present, extract and remove. Default: `gpt-5.4`
7. `force` — if `--force` present, set true and remove. Default: false
8. `prompt` — everything remaining after extracting all flags

### Step 0.5: Check review history (only when `--file` is provided)

**Skip this step entirely if `force` is true.**

If `file_path` was provided, check for a previous review of the same file with the same content:

1. Compute the file's content hash:
   ```bash
   shasum -a 256 "<file_path>" | cut -d' ' -f1
   ```

2. Check if `.loopwise/history.json` exists and contains a record for this file+hash.

3. **If a matching record exists (same file path AND same hash)**:
   - If `status` is `APPROVED`: Tell the user **"This file was already reviewed and approved on {date} ({rounds} rounds). Content is unchanged (hash: {hash:.8}). Skipping review."** and show the path to the previous report. **Stop here.**
   - If `status` is `MAX_ROUNDS_REACHED` or `DEGRADED`: Tell the user about the previous review and ask if they want to resume or start fresh.

4. **If no matching record**: proceed normally.

### Step 1: Get initial content

Three cases, checked in this order:

1. **`--file` was provided**: Read the file using the Read tool. The file contents become the **initial content**.
2. **A prompt was given (no --file)**: Generate the plan or code as requested. This is your **initial content**.
3. **Neither --file nor prompt**: Gather the most recent plan or code you produced in this conversation.

### Step 2: Send to Codex for review

**CRITICAL RULES for this step (MUST follow — violations cause permission prompts that block automation):**
1. **NEVER use `$()` command substitution in any Bash call.**
2. **NEVER combine multiple commands with `&&`, `||`, `;`, `|` pipes (except the single codex exec pipe), `{ }` groups, or `for` loops into one Bash call.**
3. **NEVER use `echo`, `cat`, `git diff`, or shell redirections to build content.** Use the Write tool instead.
4. **Use Write tool for ALL file creation. Use Read tool for ALL file reading.** The ONLY Bash call allowed is the single `cat ... | codex exec ...` pipe and `rm -f` cleanup.
5. **When collecting content from multiple files:** Read each file with the Read tool, concatenate in memory, then Write the combined result. Do NOT use shell loops or cat chains.

**Step 2a:** Use the **Write** tool to save the current content to `/tmp/loopwise-content.md`.

**Step 2b:** Build the review prompt and use the **Write** tool to save it to `/tmp/loopwise-prompt.md`.

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
cat /tmp/loopwise-prompt.md | codex exec - --model <codex_model> --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-output.md 2>/dev/null
```

**If `background` is true:**
Only the FIRST Codex call runs in background. Tell the user: **"Review started in background. You'll be notified when it completes. Use `/loopwise-status` to check progress."**

Run the Codex call using Bash with `run_in_background: true`:
```bash
cat /tmp/loopwise-prompt.md | codex exec - --model <codex_model> --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-output.md 2>/dev/null
```

Before launching the background call, create a job record:
```bash
mkdir -p .loopwise/jobs
```
Then use the **Write** tool to create `.loopwise/jobs/loopwise-job-latest.json`:
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
4. **Synthesize degraded payload** if retry also fails:
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
4. If **uncertain** — fix it but set disposition to `unverified_fix`.

**Confidence is for display/ranking only. NEVER suppress critical or high findings based on confidence.**

Do NOT blindly apply all feedback. Your job is to be the engineer who validates before changing.

The revised version becomes the new current content.

### Step 5: Loop

Go back to Step 2 with the revised content. Repeat until:
- Verdict is `approve`, OR
- Verdict is `degraded` (terminates immediately), OR
- `max_rounds` reached (if set)

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
- **Models**: Claude Code (claude-opus-4-6) ↔ Codex (gpt-5.4)
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
