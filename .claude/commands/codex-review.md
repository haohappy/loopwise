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
2. `file_path` — if the remaining text contains `--file <path>`, extract the path and remove `--file <path>` from the remaining text
3. `prompt` — everything left after extracting mode and --file

### Step 1: Get initial content

Three cases, checked in this order:

1. **`--file` was provided**: Read the file at `file_path` using the Read tool. The file contents become the **initial content**. If a prompt was also given, treat it as additional instructions for Codex's review (include it in the review prompt context).

2. **A prompt was given (no --file)**: Generate the plan or code as requested. This is your **initial content**.

3. **Neither --file nor prompt**: Gather the most recent plan or code you produced in this conversation as the initial content.

### Step 2: Send to Codex for review

Save the current content to a temp file, then call Codex to review it:

```bash
CONTENT_FILE=$(mktemp)
cat > "$CONTENT_FILE" << 'CONTENT_EOF'
<paste the current content here>
CONTENT_EOF

REVIEW_PROMPT_FILE=$(mktemp)
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
cat "$REVIEW_PROMPT_FILE" "$CONTENT_FILE" | codex exec - --model gpt-5.4 --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/codex-review-output.txt 2>/dev/null
REVIEW=$(cat /tmp/codex-review-output.txt)
rm -f "$CONTENT_FILE" "$REVIEW_PROMPT_FILE" /tmp/codex-review-output.txt
echo "$REVIEW"
```

### Step 3: Check approval

Read the Codex review output. If the first line contains "APPROVED" (case-insensitive), the loop ends. Report to the user that Codex has approved.

### Step 4: Revise based on feedback

If NOT approved, show the user a brief summary of Codex's feedback (first 5 lines), then revise your plan or code to address ALL feedback points. This revised version becomes the new current content.

### Step 5: Loop

Go back to Step 2 with the revised content. Repeat until:
- Codex outputs APPROVED, OR
- You have completed 5 rounds of review (configurable via the prompt)

### Step 6: Report

When the loop ends, tell the user:
- How many rounds it took
- Whether it was approved or hit the max rounds limit
- A brief summary of what changed across rounds

## Important rules

- **Show progress**: At the start of each round, tell the user which round you're on (e.g., "Round 2/5: Sending to Codex for review...")
- **Be transparent**: Show a brief preview of Codex's feedback each round
- **Preserve context**: Each revision should build on the previous version, not start from scratch
- **Don't over-revise**: Only change what Codex flagged, don't rewrite everything each round
- **Codex model**: Default is `gpt-5.4`. User can specify a different model by adding `--model <model>` in their prompt
- **Max rounds**: Default is 5. User can specify `--max-rounds <n>` in their prompt
