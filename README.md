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
# Install the slash command (one-time setup)
cp .claude/commands/loopwise.md ~/.claude/commands/

# Or clone and copy
git clone https://github.com/haohappy/loopwise.git
cp loopwise/.claude/commands/loopwise.md ~/.claude/commands/
```

Then inside any Claude Code session:

```
# Generate from prompt, then review loop
> /loopwise plan Design a REST API for user management with JWT auth
> /loopwise code Implement a rate limiter middleware for Express

# Review an existing file  
# using --file the best practice, the targeted review will be done efficiently.

> /loopwise plan --file docs/plan.md
> /loopwise code --file src/auth.ts

# Review an existing file with additional instructions
# This is more for senior developers who have specific needs
> /loopwise plan --file docs/plan.md Add error handling details
> /loopwise code --file src/auth.ts Refactor to use middleware pattern

# Review what you just wrote in this conversation (no args)
> /loopwise plan
> /loopwise code
```

This is the most convenient way — Claude Code drives the loop directly, calling Codex for review, reading feedback, and revising in-session. No separate process needed.

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

```markdown
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

## Tips

- **Plan reviews**: give detailed requirements so Claude Code produces a thorough plan and Codex has enough context to evaluate it.
- **Code reviews**: use `--file` to point at a specific file for focused review.
- **Strictness**: edit the review prompts in `loopwise.sh` to tune Codex's review criteria. Make them stricter (`"only approve if there are zero issues"`) or more lenient (`"approve if the approach is fundamentally sound"`).
- **Cost control**: use `LOOPWISE_CODEX_MODEL=gpt-4.1-mini` or `LOOPWISE_MAX_ROUNDS=3` to reduce API costs during experimentation.

## License

MIT
