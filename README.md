[中文文档](README_CN.md)

<div align="center">
  <img src="assets/logo.png" width="291" alt="Loopwise Logo">
</div>

# Loopwise: Automated Plan/Code Review Tool

Automated review loop between Claude Code and Codex CLI. It leverages two top-tier AI models (Claude Opus 4.6 + GPT-5.4) to cross-review each other, producing significantly higher quality output than either model alone.

Claude Code generates plans or code, Codex reviews them, feedback flows back to Claude Code automatically, and the cycle repeats until Codex approves.

## How it works

```
┌─────────────┐     plan/code      ┌─────────────┐
│ Claude Code │ ─────────────────→ │   Codex     │
│  (generate) │                    │  (review)   │
│             │ ←───────────────── │             │
│  (revise)   │     feedback       │             │
└─────────────┘                    └─────────────┘
       ↑                                  │
       └──── loop until APPROVED ─────────┘
```

Each round:
1. Claude Code produces output (plan or code)
2. Codex reviews it via `codex exec` against quality criteria
3. If Codex says APPROVED, the loop ends
4. Otherwise, feedback goes back to Claude Code for revision
5. Repeat until approved or max rounds reached

**Use cases:**
- Architecture design review
- Refactoring plan feasibility checks
- Code implementation review
- Anything that benefits from a "second pair of eyes"

**Two ways to use:**
- `/loopwise` — Slash command inside Claude Code (recommended)
- `loopwise` — Standalone shell command

## Tutorial

See [docs/TUTORIAL_EN.md](docs/TUTORIAL_EN.md) for a step-by-step guide with a real-world review example. Also available in [Chinese](docs/TUTORIAL.md).

## Prerequisites

```bash
npm install -g @anthropic-ai/claude-code   # Claude Code CLI
npm install -g @openai/codex               # Codex CLI
brew install jq                            # JSON processor (for standalone mode)
```

## Two ways to use

### Option 1: Slash command inside Claude Code (recommended)

Use `/loopwise` directly within a Claude Code session. No extra install needed — just copy the command file:

```bash
# Install all slash commands (one-time setup)
git clone https://github.com/haohappy/loopwise.git
cp loopwise/.claude/commands/loopwise*.md ~/.claude/commands/
```

This installs three commands: `/loopwise`, `/loopwise-gate`, and `/loopwise-status`.

Then inside any Claude Code session:

```
# Review an existing file (most common)
> /loopwise plan --file docs/plan.md
> /loopwise code --file src/auth.ts

# Adversarial review — skeptical stance, deeper scrutiny
> /loopwise plan --file docs/plan.md --adversarial
> /loopwise code --file src/auth.ts --adversarial focus on auth and data isolation

# Background review — non-blocking, check status later
> /loopwise plan --file docs/big-plan.md --background
> /loopwise-status

# Quick diff review before committing
> /loopwise-gate
> /loopwise-gate focus on input validation

# Generate from prompt, then review loop
> /loopwise plan Design a REST API for user management with JWT auth
> /loopwise code Implement a rate limiter middleware for Express

# Review what you just wrote in this conversation (no args)
> /loopwise plan
> /loopwise code
```

### Three slash commands

| Command | Purpose |
|---------|---------|
| `/loopwise` | Full review loop with revisions. Supports `--file`, `--adversarial`, `--background`, `--max-rounds`, `--model`, `--force` |
| `/loopwise-gate` | One-shot diff review before committing. Advisory WARNING/OK output. |
| `/loopwise-status` | Check background review job status. |

### v2 features

- **Structured JSON output** — Codex returns findings with severity, confidence, and recommendations (not free text)
- **Adversarial mode** (`--adversarial`) — Skeptical review checking 7 attack surfaces: auth, data, resilience, concurrency, edge cases, evolution, observability
- **Review Gate** (`/loopwise-gate`) — Quick Codex review of your git diff before committing
- **Background execution** (`--background`) — Non-blocking review, check with `/loopwise-status`
- **Verify before fixing** — Claude Code independently verifies each Codex finding before applying changes
- **Disposition tracking** — Each finding marked as verified, dismissed, or unverified_fix in the report

**Screenshot: Review loop in action**

<img src="assets/screenshot1.png" alt="Loopwise Round 1 - Codex review and Claude Code revision">

<img src="assets/screenshot2.png" alt="Loopwise Round 2 - Continued review and fixes">

### Option 2: Standalone shell command

Run from any terminal as an independent process:

```bash
# Install
git clone https://github.com/haohappy/loopwise.git
cd loopwise
./install.sh            # installs to /usr/local/bin
# or: ./install.sh ~/bin

# Usage
loopwise plan "Build a REST API for user management with JWT auth"
loopwise code "Implement a rate limiter middleware for Express"
loopwise plan --file docs/plan.md
loopwise code --file src/auth.ts "Refactor to use passport.js"
loopwise plan --max-rounds 10 --verbose "Design a real-time notification system"
```

## Default models

- **Claude Code**: Claude Opus 4.6 (used for plan/code generation and revision)
- **Codex**: GPT-5.4 (used for review)

## Configuration

Configure via CLI flags or environment variables:

| Flag | Environment Variable | Default | Description |
|---|---|---|---|
| `--max-rounds` | `LOOPWISE_MAX_ROUNDS` | *(unlimited)* | Maximum review cycles (0 = no limit) |
| `--claude-model` | `LOOPWISE_CLAUDE_MODEL` | Claude Opus 4.6 | Claude model for generation |
| `--codex-model` | `LOOPWISE_CODEX_MODEL` | GPT-5.4 | Codex model for reviews |
| `--output-dir` | `LOOPWISE_OUTPUT_DIR` | .loopwise | Session output directory |
| `--timeout` | `LOOPWISE_TIMEOUT` | 300 | Timeout per CLI call (seconds) |
| `--verbose` | `LOOPWISE_VERBOSE` | false | Show debug output |

You can also copy the config template to your home directory:

```bash
cp .loopwise.conf.example ~/.loopwise.conf
```

### Auto-approve permissions for `/loopwise`

When running `/loopwise` inside Claude Code, you may be prompted to confirm each Bash command. To skip these confirmations, add the following to your `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(cat /tmp/loopwise*)",
      "Bash(cat */tmp/loopwise*)",
      "Bash(rm -f /tmp/loopwise*)",
      "Bash(shasum *)",
      "Bash(mkdir -p .loopwise*)",
      "Bash(*codex exec*)",
      "Bash(cd *codex exec*)",
      "Write(/tmp/loopwise*)",
      "Read(/tmp/loopwise*)"
    ]
  }
}
```

These rules allow the specific tool calls that `/loopwise` uses: writing temp files, invoking Codex via pipe, reading review output, computing file hashes, and managing the history directory. Merge these into your existing `permissions.allow` array if you already have other rules.

## Output

Each session creates a timestamped directory under `.loopwise/`:

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

## Review Report

After the review loop completes, Loopwise automatically generates a structured report in the current working directory:

- Plan mode: `PLAN_REVIEW_REPORT.md`
- Code mode: `CODE_REVIEW_REPORT.md`

The report includes:
- Review metadata (mode, status, total rounds, date, models used)
- Round-by-round summary with key feedback from Codex and what Claude Code changed
- Final result (approved or remaining issues)

Example:

```
# Codex Plan Review Report

- **Mode**: plan
- **Status**: APPROVED
- **Total rounds**: 3
- **Date**: 2026-03-30 14:20
- **Models**: Claude Code (claude-opus-4-6) ↔ Codex (gpt-5.4)
- **Input**: --file docs/REFACTORING_PLAN.md

## Round-by-round summary

### Round 1: Codex review #1
- **Verdict**: FEEDBACK
- **Key feedback**:
  - Missing error handling for token expiration
  - No rate limiting strategy
- **Revision**: Claude Code addressed feedback:
  - Added JWT refresh token flow
  - Added rate limiting section

### Round 2: Codex review #2
- **Verdict**: APPROVED
- **Comments**: No further issues found

## Final result
Plan approved after 3 rounds.
```

## Review History

When reviewing files with `--file`, Loopwise tracks review history in `.loopwise/history.json` based on file content SHA-256 hash:

- **Unchanged + previously approved** — Skipped automatically
- **Unchanged + previously incomplete** — Offers to resume with prior feedback
- **Content changed** — Starts a fresh review
- **`--force`** — Bypasses history check

## Best Practices of Using Loopwise

### File organization

Write plans as Markdown files in your project's `docs/` directory. Benefits:
- Version controlled
- Each round produces a git diff
- Team can see the evolution

### Model selection

- **Plan review:** Use `gpt-5.4` (default, strong reasoning)
- **Code review:** Also use `gpt-5.4` (understands project context)
- Switch models: `/loopwise plan --model o3 --file docs/plan.md`

### Verify before fixing

Codex can hallucinate or misread context. Claude Code independently verifies each feedback point before acting on it — checking whether the issue actually exists in the code or plan. Invalid feedback is dismissed with a reason noted in the report, not blindly applied.

### Only fix what Codex flagged

Don't over-revise. Only address the verified feedback points each round, otherwise:
- You may introduce new issues
- It becomes hard to track what changed
- Codex may give unrelated feedback next round due to context shift

### Commit after each round

Commit and push after fixing each round of feedback:

```bash
git commit -m "Refactoring plan v3: fix Codex round 2 feedback (7 issues)"
```

This creates a clear record and lets your team review the evolution.

### Know when to stop

- **APPROVED** — Codex approved, ready to implement
- **Round 3-4 feedback is operational details** — Architecture is stable, ready to implement
- **Round 5 still has architecture-level issues** — May need to rethink the approach

> For complex systems, don't chase APPROVED — what matters is that feedback shifts from architecture-level to implementation-level.

### Tune review strictness

Edit the review prompts in `loopwise.sh` to adjust Codex's review criteria. Make them stricter (`"only approve if there are zero issues"`) or more lenient (`"approve if the approach is fundamentally sound"`).

### Cost control

Use `LOOPWISE_CODEX_MODEL=gpt-4.1-mini` or `LOOPWISE_MAX_ROUNDS=3` to reduce API costs during experimentation.

## License

MIT
