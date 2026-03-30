# Loopwise — Automated Review Loop

Automated review loop: you (Claude Code) produce a plan or code, then Codex reviews it, you revise based on feedback, and the cycle repeats until Codex approves.

## Arguments

$ARGUMENTS should be in format: `<mode> [--file <path>] [prompt or instructions]`

- **mode**: `plan` or `code`
- **--file \<path\>**: Optional. Path to an existing file to use as initial content for review (skip generation).
- **prompt**: What to generate or review. If both `--file` and prompt are omitted, review the work you just produced in this conversation.

Examples:
```
/loopwise plan Design a REST API for user management with JWT auth
/loopwise code Implement a rate limiter middleware for Express
/loopwise plan --file docs/plan.md
/loopwise code --file src/auth.ts Refactor to use passport.js
/loopwise plan              (review the plan you just wrote in this conversation)
/loopwise code              (review the code you just wrote in this conversation)
```

## Instructions

You are now entering an automated review loop with Codex. Follow these steps precisely:

### Step 0: Parse arguments

Extract from $ARGUMENTS:
1. `mode` — first word: "plan" or "code"
2. `file_path` — if the remaining text contains `--file <path>`, extract the path and remove it
3. `max_rounds` — if the remaining text contains `--max-rounds <n>`, extract the number and remove it. Default: no limit (loop until approved)
4. `codex_model` — if the remaining text contains `--model <model>`, extract the model name and remove it. Default: `gpt-5.4`
5. `force` — if the remaining text contains `--force`, set to true and remove it. Default: false. Bypasses review history check.
6. `prompt` — everything left after extracting all flags above

### Step 0.5: Check review history (only when `--file` is provided)

**Skip this step entirely if `force` is true.**

If `file_path` was provided, check for a previous review of the same file with the same content:

1. Compute the file's content hash:
   ```bash
   FILE_HASH=$(shasum -a 256 "<file_path>" | cut -d' ' -f1)
   ```

2. Check if `.loopwise/history.json` exists and contains a record for this file+hash. The history file is a JSON array:
   ```json
   [
     {
       "file": "src/auth.ts",
       "hash": "abc123...",
       "status": "APPROVED",
       "date": "2026-03-29 17:30",
       "rounds": 3,
       "report": ".loopwise/20260329_173022_12345/REVIEW_REPORT.md",
       "last_feedback": null
     }
   ]
   ```

3. **If a matching record exists (same file path AND same hash)**:
   - If `status` is `APPROVED`: Tell the user **"This file was already reviewed and approved on {date} ({rounds} rounds). Content is unchanged (hash: {hash:.8}). Skipping review."** and show them the path to the previous report. **Stop here — do not start a new review loop.**
   - If `status` is `MAX_ROUNDS_REACHED`: Tell the user **"This file was previously reviewed on {date} but did not reach approval after {rounds} rounds. Last feedback was:"** then show `last_feedback`. Ask the user if they want to: (a) resume with the previous feedback as context, or (b) start a fresh review.

4. **If no matching record** (new file or content changed): proceed normally.

### Step 1: Get initial content

Three cases, checked in this order:

1. **`--file` was provided**: Read the file at `file_path` using the Read tool. The file contents become the **initial content**. If a prompt was also given, treat it as additional instructions for Codex's review (include it in the review prompt context).

2. **A prompt was given (no --file)**: Generate the plan or code as requested. This is your **initial content**.

3. **Neither --file nor prompt**: Gather the most recent plan or code you produced in this conversation as the initial content.

### Step 2: Send to Codex for review

**IMPORTANT: Execute each step as a SEPARATE Bash tool call. Do NOT combine them into one multi-line command.** This ensures permissions auto-approve correctly.

**Step 2a:** Use the Write tool to save the current content to a temp file (e.g., `/tmp/loopwise-content.md`).

**Step 2b:** Build the review prompt (plan or code criteria, plus the content) and use the Write tool to save it to another temp file (e.g., `/tmp/loopwise-prompt.md`).

For plan mode, the review prompt should evaluate: completeness, technical feasibility, edge cases, architecture, security.
For code mode, evaluate: correctness, performance, error handling, readability, security, testing.

Always include this instruction in the prompt:
> If solid and ready, respond with EXACTLY this on the first line: APPROVED
> If improvements are needed, provide specific, actionable feedback. Do NOT say APPROVED if you have any suggestions.

**Step 2c:** Call Codex in a single Bash command:
```bash
cat /tmp/loopwise-prompt.md /tmp/loopwise-content.md | codex exec - --model <codex_model> --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-output.md 2>/dev/null && cat /tmp/loopwise-output.md
```

**Step 2d:** Read the output from `/tmp/loopwise-output.md` using the Read tool.

**Step 2e:** Clean up temp files:
```bash
rm -f /tmp/loopwise-content.md /tmp/loopwise-prompt.md /tmp/loopwise-output.md
```

### Step 3: Check approval

Read the Codex review output. If the first line contains "APPROVED" (case-insensitive), the loop ends. Report to the user that Codex has approved.

### Step 4: Revise based on feedback

If NOT approved, show the user a brief summary of Codex's feedback (first 5 lines), then **independently verify each feedback point before acting on it**:

1. For each issue Codex raised, check whether the problem actually exists in the current content (read the relevant code/section, trace the logic, verify the claim).
2. If verified — fix it.
3. If the issue does not actually exist (Codex hallucinated or misread the context) — skip it and note in the report that it was dismissed with a brief reason.
4. If uncertain — err on the side of fixing, but mark it as "unverified fix" in the report.

Do NOT blindly apply all feedback. Codex can make mistakes. Your job is to be the engineer who validates before changing.

This revised version becomes the new current content.

### Step 5: Loop

Go back to Step 2 with the revised content. Repeat until:
- Codex outputs APPROVED, OR
- `max_rounds` was set and the round count reaches it (no default limit — loop continues until approved unless explicitly capped)

Use the parsed `codex_model` variable (default `gpt-5.4`) in the codex exec command. Use the parsed `max_rounds` variable to control loop termination.

### Step 6: Write Review Report

When the loop ends, write a **Review Report** file to the current working directory. The filename depends on the mode:
- Plan mode: `PLAN_REVIEW_REPORT.md`
- Code mode: `CODE_REVIEW_REPORT.md`

The report must use this exact format:

```markdown
# Codex Plan Review Report / Codex Code Review Report

- **Mode**: plan / code
- **Status**: APPROVED / MAX_ROUNDS_REACHED
- **Total rounds**: N
- **Date**: YYYY-MM-DD HH:MM
- **Models**: Claude Code (claude-opus-4-6) ↔ Codex (gpt-5.4)
- **Input**: (prompt text, or file path if --file was used)

## Round-by-round summary

### Round 1: Initial generation
- **Action**: Claude Code generated initial [plan/code]

### Round 2: Codex review #1
- **Verdict**: FEEDBACK
- **Key feedback**:
  - (bullet point summary of each major feedback item)
- **Revision**: Claude Code addressed feedback:
  - (bullet point summary of what was changed)

### Round 3: Codex review #2
- **Verdict**: APPROVED
- **Comments**: (any final comments from Codex, or "No further issues found")

## Final result

(State whether the plan/code was approved, or if max rounds were reached with remaining issues.)
```

Adapt the number of round sections to match the actual number of rounds. Each round section should capture the **key feedback points** from Codex and the **specific changes** Claude Code made in response. Be concise but complete — someone reading only this report should understand what happened.

After writing the file, tell the user the report has been saved to `PLAN_REVIEW_REPORT.md` or `CODE_REVIEW_REPORT.md` (depending on mode).

### Step 7: Update review history (only when `--file` was provided)

If `file_path` was provided, update `.loopwise/history.json`:

1. Compute the final file hash: `shasum -a 256 "<file_path>" | cut -d' ' -f1`
2. Read the existing `.loopwise/history.json` (or start with `[]` if it doesn't exist)
3. Remove any existing record with the same `file` path (only keep the latest review per file)
4. Append a new record:
   ```json
   {
     "file": "<file_path>",
     "hash": "<final_hash>",
     "status": "APPROVED" or "MAX_ROUNDS_REACHED",
     "date": "<current datetime>",
     "rounds": <total_rounds>,
     "report": "REVIEW_REPORT.md",
     "last_feedback": "<last Codex feedback if not approved, null if approved>"
   }
   ```
5. Write the updated array back to `.loopwise/history.json`

Use `jq` via Bash to read/write the JSON file. Create `.loopwise/` directory if it doesn't exist.

## Important rules

- **Show progress**: At the start of each round, tell the user which round you're on (e.g., "Round 2/5: Sending to Codex for review...")
- **Be transparent**: Show a brief preview of Codex's feedback each round
- **Preserve context**: Each revision should build on the previous version, not start from scratch
- **Verify before fixing**: Codex can hallucinate or misread context. Independently verify each feedback point actually exists before changing anything. Dismiss invalid feedback with a brief reason in the report.
- **Don't over-revise**: Only change what Codex flagged and you verified, don't rewrite everything each round
- **Codex model**: Default is `gpt-5.4`. User can specify a different model by adding `--model <model>` in their prompt
- **Max rounds**: No default limit — loop runs until Codex approves. User can specify `--max-rounds <n>` to cap the iterations
