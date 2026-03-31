# Loopwise Gate — Quick Diff Review

One-shot Codex review of your current git changes. Advisory only — outputs WARNING or OK, does not modify code.

## Arguments

$ARGUMENTS is optional. If provided, it becomes a focus area for the review.

Examples:
```
/loopwise-gate
/loopwise-gate focus on auth and input validation
/loopwise-gate --model o3
```

## Instructions

### Step 0: Parse arguments

Extract from $ARGUMENTS:
1. `codex_model` — if `--model <model>` present, extract and remove. Default: `gpt-5.4`
2. `focus` — everything remaining (optional focus text for the review)

### Step 1: Verify environment

Run these checks (each as a separate Bash call):

**Check 1:** Verify we're in a git repo:
```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```
If not a git repo, tell the user: "Not a git repository. /loopwise-gate requires git." and **stop**.

**Check 2:** Get the diff. Try staged first, then unstaged, then combined:
```bash
git diff --cached --stat 2>/dev/null
```
```bash
git diff --stat 2>/dev/null
```

If both are empty (no changes), tell the user: "No changes detected. Nothing to review." and **stop**.

### Step 2: Collect the diff

**CRITICAL: Use ONLY simple single-command Bash calls. NO `&&`, `||`, `;`, `{ }`, `$()`, `for` loops, or pipes (except the codex exec pipe). Use Read/Write tools for file content.**

Get staged diff first (single Bash call):
```bash
git diff --cached --diff-filter=d -- . ':!node_modules' ':!vendor' ':!*.min.js' ':!*.min.css' ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!composer.lock' ':!*.lock' 2>/dev/null
```

If staged diff is empty, get unstaged (separate Bash call):
```bash
git diff --diff-filter=d -- . ':!node_modules' ':!vendor' ':!*.min.js' ':!*.min.css' ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!composer.lock' ':!*.lock' 2>/dev/null
```

Capture the diff output from the Bash result. Do NOT redirect to a file via shell — use the **Write tool** to save the diff content.

**Check diff size:** Count lines of the diff output in memory (not via shell).
- If > 5000 lines: Tell the user **"Diff too large (N lines). Use `/loopwise code --file <path>` to review specific files, or split your changes into smaller commits."** and **stop**. Do not do a partial review.
- If 0 lines after filtering: Tell the user "Only vendor/generated files changed. Nothing to review." and **stop**.

### Step 3: Send diff to Codex

**Use Write tool** to save the review prompt to `/tmp/loopwise-gate-prompt.md`:

```
<task>Quick review of git diff for safety before committing.</task>

<output_contract>
Respond with ONLY a JSON object. Schema:
{
  "schema_version": 1,
  "verdict": "approve" | "needs_attention",
  "summary": "one-line assessment",
  "findings": [
    {
      "severity": "critical" | "high" | "medium" | "low",
      "title": "short title",
      "body": "explanation",
      "file": "file path",
      "line_start": null,
      "confidence": 0.0-1.0,
      "recommendation": "fix"
    }
  ],
  "next_steps": []
}
</output_contract>

<grounding>Ground every claim in the diff. Label inferences.</grounding>
<completeness>Review ALL changed files. Focus on correctness, security, and error handling.</completeness>
```

If `focus` text was provided, add:
```
<user_focus>Pay special attention to: {focus}</user_focus>
```

Append the diff after `=== DIFF TO REVIEW ===`.

**Call Codex** (single Bash):
```bash
cat /tmp/loopwise-gate-prompt.md | codex exec - --model <codex_model> --sandbox read-only --skip-git-repo-check --ephemeral -o /tmp/loopwise-gate-output.md 2>/dev/null
```

**Read output** with Read tool, then **clean up**:
```bash
rm -f /tmp/loopwise-gate-prompt.md /tmp/loopwise-gate-output.md
```

### Step 4: Parse and report

Parse the Codex output as JSON. Apply the same fallback chain as `/loopwise`:
1. Direct JSON parse
2. Extract fenced/braced JSON block
3. If parse fails entirely → treat as degraded

**Output decision:**

- **If any `critical` or `high` severity findings exist:**
  Output: `WARNING: N issues found (X critical, Y high). Recommend fixing before committing.`
  Then list each critical/high finding with title, file, and recommendation.

- **If only `medium` or `low` findings AND parse was clean:**
  Output: `OK: No critical issues. N suggestions noted.`
  Optionally list medium findings briefly.

- **If verdict is `approve` with empty findings:**
  Output: `OK: Changes look good. No issues found.`

- **If parse failed / degraded:**
  Output: `WARNING (degraded): Review incomplete due to tool/parse error. Treat changes as unreviewed.`
  Never output OK on degraded.

### Step 5: Summary

End with a one-line recommendation:
- WARNING → "Consider fixing the above issues before committing."
- OK → "Safe to commit."
- DEGRADED → "Re-run /loopwise-gate or use /loopwise code --file for a thorough review."

## Important rules

- **This is a ONE-SHOT review. No loop, no revisions.** Just report findings.
- **Advisory only.** Never modify any files. Never auto-fix.
- **Never output OK when degraded.** Any tool/parse failure = WARNING.
- **Exclude vendor files.** node_modules, vendor, lock files, minified files are always excluded.
- **Refuse oversized diffs.** >5000 lines = refuse, don't truncate silently.
