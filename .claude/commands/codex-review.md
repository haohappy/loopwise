# Codex Review Loop

Automated review loop: you (Claude Code) produce a plan or code, then Codex reviews it, you revise based on feedback, and the cycle repeats until Codex approves.

## Arguments

$ARGUMENTS should be in format: `<mode> [--file <path>] [prompt or instructions]`

- **mode**: `plan` or `code`
- **--file \<path\>**: Optional. Path to an existing file to use as initial content for review (skip generation).
- **prompt**: What to generate or review. If both `--file` and prompt are omitted, review the work you just produced in this conversation.

Examples:
```
/codex-review plan Design a REST API for user management with JWT auth
/codex-review code Implement a rate limiter middleware for Express
/codex-review plan --file docs/plan.md
/codex-review code --file src/auth.ts Refactor to use passport.js
/codex-review plan              (review the plan you just wrote in this conversation)
/codex-review code              (review the code you just wrote in this conversation)
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

2. Check if `.cc-review/history.json` exists and contains a record for this file+hash. The history file is a JSON array:
   ```json
   [
     {
       "file": "src/auth.ts",
       "hash": "abc123...",
       "status": "APPROVED",
       "date": "2026-03-29 17:30",
       "rounds": 3,
       "report": ".cc-review/20260329_173022_12345/REVIEW_REPORT.md",
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

Save the current content to a temp file, then call Codex to review it:

```bash
CONTENT_FILE=$(mktemp /tmp/codex-content-XXXXXX.md)
cat > "$CONTENT_FILE" << 'CONTENT_EOF'
<paste the current content here>
CONTENT_EOF

REVIEW_PROMPT_FILE=$(mktemp /tmp/codex-prompt-XXXXXX.md)
# For plan mode:
cat > "$REVIEW_PROMPT_FILE" << 'PROMPT_EOF'
You are a senior technical reviewer. Review the following development plan.

Evaluate:
1. Completeness: Are all requirements addressed?
2. Technical feasibility: Is the approach sound?
3. Edge cases: Are error handling and edge cases considered?
4. Architecture: Is the design clean and maintainable?
5. Security: Are there security concerns?

If the plan is solid and ready for implementation, respond with EXACTLY this on the first line:
APPROVED

If improvements are needed, provide specific, actionable feedback. Do NOT say APPROVED if you have any suggestions.

=== PLAN TO REVIEW ===
PROMPT_EOF

# For code mode, replace the review criteria with:
# 1. Correctness  2. Performance  3. Error handling  4. Readability  5. Security  6. Testing

# Combine prompt and content, pipe to codex
REVIEW_OUTPUT=$(mktemp /tmp/codex-review-output-XXXXXX.md)
cat "$REVIEW_PROMPT_FILE" "$CONTENT_FILE" | codex exec - --model <codex_model> --sandbox read-only --skip-git-repo-check --ephemeral -o "$REVIEW_OUTPUT" 2>/dev/null
REVIEW=$(cat "$REVIEW_OUTPUT")
rm -f "$CONTENT_FILE" "$REVIEW_PROMPT_FILE" "$REVIEW_OUTPUT"
echo "$REVIEW"
```

### Step 3: Check approval

Read the Codex review output. If the first line contains "APPROVED" (case-insensitive), the loop ends. Report to the user that Codex has approved.

### Step 4: Revise based on feedback

If NOT approved, show the user a brief summary of Codex's feedback (first 5 lines), then revise your plan or code to address ALL feedback points. This revised version becomes the new current content.

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

If `file_path` was provided, update `.cc-review/history.json`:

1. Compute the final file hash: `shasum -a 256 "<file_path>" | cut -d' ' -f1`
2. Read the existing `.cc-review/history.json` (or start with `[]` if it doesn't exist)
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
5. Write the updated array back to `.cc-review/history.json`

Use `jq` via Bash to read/write the JSON file. Create `.cc-review/` directory if it doesn't exist.

## Important rules

- **Show progress**: At the start of each round, tell the user which round you're on (e.g., "Round 2/5: Sending to Codex for review...")
- **Be transparent**: Show a brief preview of Codex's feedback each round
- **Preserve context**: Each revision should build on the previous version, not start from scratch
- **Don't over-revise**: Only change what Codex flagged, don't rewrite everything each round
- **Codex model**: Default is `gpt-5.4`. User can specify a different model by adding `--model <model>` in their prompt
- **Max rounds**: No default limit — loop runs until Codex approves. User can specify `--max-rounds <n>` to cap the iterations
