# Loopwise Status — Check Background Review

Show the status of the most recent background `/loopwise` review job.

## Arguments

$ARGUMENTS is not used. This command takes no arguments.

## Instructions

### Step 1: Check for job record

Read `.loopwise/jobs/loopwise-job-latest.json` using the Read tool.

If the file does not exist, tell the user: **"No background review jobs found."** and stop.

### Step 2: Display status

Parse the JSON and display a status summary:

**If status is `running`:**
Check `updated_at`. If more than 15 minutes ago, display as **stale**.

```
Background Review Status
━━━━━━━━━━━━━━━━━━━━━━━
Status:   RUNNING (or STALE if >15min)
Mode:     plan / code
File:     docs/plan.md
Model:    gpt-5.4
Started:  2026-03-31 16:30
Elapsed:  2m 15s
```

If stale: **"This job appears stale (no update for >15 minutes). It may have been interrupted. Run `/loopwise` again to start a fresh review."**

**If status is `completed`:**
```
Background Review Status
━━━━━━━━━━━━━━━━━━━━━━━
Status:   COMPLETED
Mode:     plan / code
File:     docs/plan.md
Model:    gpt-5.4
Duration: 1m 45s
```

Then read the output file path from the job record and display the Codex review result. Parse it as JSON (same fallback chain as `/loopwise` Step 3) and show findings summary.

Tell the user: **"To start a full review loop with revisions, run `/loopwise <mode> --file <path>` (without --background)."**

**If status is `failed`:**
```
Background Review Status
━━━━━━━━━━━━━━━━━━━━━━━
Status:   FAILED
Mode:     plan / code
File:     docs/plan.md
Error:    <error message>
```

Tell the user: **"The background review failed. Run `/loopwise <mode> --file <path>` to retry."**

### Step 3: Cleanup old jobs (optional)

If `.loopwise/jobs/` contains job files older than 30 days, delete them:
```bash
find .loopwise/jobs/ -name "*.json" -mtime +30 -delete 2>/dev/null
```

## Important rules

- **Read-only.** This command never modifies code or starts new reviews.
- **Stale = derived.** Only displayed for `running` status with `updated_at` > 15 minutes ago. Not persisted.
- **Simple model.** We track only the latest job in `loopwise-job-latest.json`. No multi-job queue.
