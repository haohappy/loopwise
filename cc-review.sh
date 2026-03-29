#!/usr/bin/env bash
#
# cc-review: Claude Code ↔ Codex Automated Review Loop
#
# Automates the cycle:
#   1. Claude Code produces a plan or code
#   2. Codex reviews it
#   3. Feedback goes back to Claude Code
#   4. Repeat until Codex approves or max rounds reached
#
# Usage:
#   cc-review plan "Build a user auth system with JWT"
#   cc-review code "Implement the login endpoint"
#   cc-review plan --file plan.md "Review and improve this plan"
#   cc-review code --file src/auth.ts "Review and improve this file"
#
# Requirements: claude, codex, jq

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

MAX_ROUNDS="${CC_REVIEW_MAX_ROUNDS:-5}"
CLAUDE_MODEL="${CC_REVIEW_CLAUDE_MODEL:-}"
CODEX_MODEL="${CC_REVIEW_CODEX_MODEL:-gpt-5.4}"
OUTPUT_DIR="${CC_REVIEW_OUTPUT_DIR:-.cc-review}"
VERBOSE="${CC_REVIEW_VERBOSE:-false}"
TIMEOUT="${CC_REVIEW_TIMEOUT:-300}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()   { echo -e "${BLUE}[cc-review]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${DIM}[debug] $*${NC}" || true; }

check_deps() {
  local missing=()
  command -v claude >/dev/null 2>&1 || missing+=("claude")
  command -v codex  >/dev/null 2>&1 || missing+=("codex")
  command -v jq     >/dev/null 2>&1 || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing dependencies: ${missing[*]}"
    [[ " ${missing[*]} " =~ " claude " ]] && err "  Install: npm install -g @anthropic-ai/claude-code"
    [[ " ${missing[*]} " =~ " codex " ]]  && err "  Install: npm install -g @openai/codex"
    [[ " ${missing[*]} " =~ " jq " ]]     && err "  Install: brew install jq"
    exit 1
  fi
}

setup_session() {
  SESSION_ID="$(date +%Y%m%d_%H%M%S)_$$"
  SESSION_DIR="$OUTPUT_DIR/$SESSION_ID"
  mkdir -p "$SESSION_DIR"
  log "Session: ${CYAN}$SESSION_ID${NC}"
  log "Output:  ${CYAN}$SESSION_DIR${NC}"
}

save_artifact() {
  local name="$1" content="$2"
  printf '%s\n' "$content" > "$SESSION_DIR/$name"
  debug "Saved $SESSION_DIR/$name ($(printf '%s' "$content" | wc -c | tr -d ' ') bytes)"
}

# ─── Timeout wrapper ────────────────────────────────────────────────────────

# Detect available timeout command once
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  TIMEOUT_CMD=""
fi

run_with_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$@"
    local rc=$?
    if [[ $rc -eq 124 ]]; then
      err "Command timed out after ${TIMEOUT}s: $1"
      return 1
    fi
    return $rc
  else
    "$@"
  fi
}

# ─── Claude Code wrapper ────────────────────────────────────────────────────
#
# Returns raw JSON from claude -p --output-format json.
# Caller extracts .result and .session_id via jq.
# Prompt is piped via stdin to avoid ARG_MAX limits.

run_claude_raw() {
  local prompt="$1"
  local resume_session="${2:-}"
  local claude_args=(-p --output-format json --no-session-persistence)

  [[ -n "$CLAUDE_MODEL" ]] && claude_args+=(--model "$CLAUDE_MODEL")
  [[ -n "$resume_session" ]] && claude_args+=(--resume "$resume_session")

  if [[ "${MODE:-}" == "code" ]]; then
    claude_args+=(--allowedTools "Read,Edit,Bash,Write")
  fi

  debug "Running: printf prompt | claude ${claude_args[*]}"

  local raw_output
  raw_output=$(printf '%s' "$prompt" | run_with_timeout claude "${claude_args[@]}" 2>/dev/null) || {
    err "Claude Code failed."
    return 1
  }

  printf '%s' "$raw_output"
}

extract_result() {
  jq -r '.result // empty' 2>/dev/null <<< "$1"
}

extract_session_id() {
  jq -r '.session_id // empty' 2>/dev/null <<< "$1"
}

# ─── Codex wrapper ──────────────────────────────────────────────────────────
#
# Prompt piped via stdin (using "-" arg). Output captured via -o tempfile.

run_codex_review() {
  local content="$1"
  local review_type="$2"

  local review_prompt
  if [[ "$review_type" == "plan" ]]; then
    review_prompt="You are a senior technical reviewer. Review the following development plan.

Evaluate:
1. Completeness: Are all requirements addressed?
2. Technical feasibility: Is the approach sound?
3. Edge cases: Are error handling and edge cases considered?
4. Architecture: Is the design clean and maintainable?
5. Security: Are there security concerns?

If the plan is solid and ready for implementation, respond with EXACTLY this on its own line:
APPROVED

If improvements are needed, provide specific, actionable feedback. Do NOT say APPROVED if you have any suggestions.

=== PLAN TO REVIEW ===
$content"
  else
    review_prompt="You are a senior code reviewer. Review the following code or implementation.

Evaluate:
1. Correctness: Does the logic work as intended?
2. Performance: Are there obvious inefficiencies?
3. Error handling: Are failures handled gracefully?
4. Readability: Is the code clean and well-structured?
5. Security: Are there vulnerabilities?
6. Testing: Is the code testable?

If the code is production-ready with no significant issues, respond with EXACTLY this on its own line:
APPROVED

If improvements are needed, provide specific, actionable feedback with code examples where helpful. Do NOT say APPROVED if you have any suggestions.

=== CODE TO REVIEW ===
$content"
  fi

  debug "Running: printf prompt | codex exec - ..."

  local output_file
  output_file=$(mktemp)

  printf '%s' "$review_prompt" | run_with_timeout codex exec - \
    --model "$CODEX_MODEL" \
    --sandbox read-only \
    --skip-git-repo-check \
    --ephemeral \
    -o "$output_file" 2>/dev/null || {
    rm -f "$output_file"
    err "Codex review failed."
    return 1
  }

  local result
  result=$(cat "$output_file")
  rm -f "$output_file"
  printf '%s' "$result"
}

# ─── Approval detection ─────────────────────────────────────────────────────

is_approved() {
  local review="$1"
  # Strict: APPROVED on its own line
  if printf '%s\n' "$review" | grep -qxE '[[:space:]]*APPROVED[[:space:]]*'; then
    return 0
  fi
  # Loose fallback: short output starting with APPROVED (avoid false positives in long feedback)
  local lines
  lines=$(printf '%s\n' "$review" | wc -l | tr -d ' ')
  if [[ "$lines" -le 3 ]] && printf '%s\n' "$review" | head -1 | grep -qi "^approved"; then
    return 0
  fi
  return 1
}

# ─── Main loop ──────────────────────────────────────────────────────────────

run_review_loop() {
  local mode="$1"
  local initial_prompt="$2"
  local target_file="${3:-}"
  MODE="$mode"

  setup_session

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  cc-review: Claude Code ↔ Codex Review Loop${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Mode:       ${CYAN}$mode${NC}"
  echo -e "  Max rounds: ${CYAN}$MAX_ROUNDS${NC}"
  [[ -n "$target_file" ]] && echo -e "  File:       ${CYAN}$target_file${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local current_content=""
  local claude_session=""

  # ── Step 1: Get initial content ──

  if [[ -n "$target_file" ]]; then
    # From file: load content, skip generation
    if [[ ! -f "$target_file" ]]; then
      err "File not found: $target_file"
      exit 1
    fi
    current_content=$(cat "$target_file")
    save_artifact "round_0_input.md" "$current_content"
    ok "Loaded existing ${mode} from ${target_file} ($(printf '%s' "$current_content" | wc -l | tr -d ' ') lines)"
  else
    # From prompt: Claude Code generates initial content
    log "${BOLD}Round 1/${MAX_ROUNDS}${NC}: Claude Code generating initial ${mode}..."

    local claude_prompt
    if [[ "$mode" == "plan" ]]; then
      claude_prompt="Create a detailed development plan for the following requirement. Include:
- Architecture overview
- Step-by-step implementation plan
- Technical decisions and rationale
- File structure
- Key interfaces and data models
- Error handling strategy
- Testing approach

Requirement: $initial_prompt"
    else
      if [[ -n "$target_file" ]]; then
        claude_prompt="$initial_prompt

Focus on the file: $target_file"
      else
        claude_prompt="$initial_prompt"
      fi
    fi

    local raw
    raw=$(run_claude_raw "$claude_prompt") || exit 1
    current_content=$(extract_result "$raw")
    claude_session=$(extract_session_id "$raw")

    if [[ -z "$current_content" ]]; then
      err "Claude Code returned empty output"
      debug "Raw output: $raw"
      exit 1
    fi

    save_artifact "round_1_claude.md" "$current_content"
    ok "Claude Code produced initial ${mode}"
    debug "Session ID: $claude_session"
  fi

  # ── Review loop ──

  local round=1
  while [[ $round -lt $MAX_ROUNDS ]]; do
    round=$((round + 1))

    # ── Codex review ──
    echo ""
    log "${BOLD}Round ${round}/${MAX_ROUNDS}${NC}: Codex reviewing..."

    local review
    review=$(run_codex_review "$current_content" "$mode") || exit 1
    save_artifact "round_${round}_codex_review.md" "$review"

    if is_approved "$review"; then
      echo ""
      echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo -e "${GREEN}${BOLD}  APPROVED by Codex after ${round} rounds${NC}"
      echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      save_artifact "final.md" "$current_content"
      save_artifact "status.txt" "APPROVED at round $round"
      log "Final output: ${CYAN}${SESSION_DIR}/final.md${NC}"
      return 0
    fi

    ok "Codex provided feedback"
    echo -e "${DIM}$(printf '%s\n' "$review" | head -5)${NC}"
    local review_lines
    review_lines=$(printf '%s\n' "$review" | wc -l | tr -d ' ')
    [[ "$review_lines" -gt 5 ]] && echo -e "${DIM}  ... ($review_lines lines total)${NC}"

    # Check if this is the last round
    if [[ $round -ge $MAX_ROUNDS ]]; then
      break
    fi

    # ── Claude Code revision ──
    echo ""
    log "${BOLD}Round ${round}/${MAX_ROUNDS}${NC}: Claude Code revising based on feedback..."

    local revision_prompt="A senior reviewer has provided the following feedback on your ${mode}. Please revise accordingly and output the complete updated version.

=== REVIEWER FEEDBACK ===
$review

=== YOUR PREVIOUS OUTPUT ===
$current_content

Please address ALL feedback points and produce an improved version."

    local raw_revised
    if [[ -n "$claude_session" ]]; then
      raw_revised=$(run_claude_raw "$revision_prompt" "$claude_session") || {
        debug "Session continuation failed, starting fresh"
        raw_revised=$(run_claude_raw "$revision_prompt") || exit 1
      }
    else
      raw_revised=$(run_claude_raw "$revision_prompt") || exit 1
    fi

    local revised
    revised=$(extract_result "$raw_revised")
    # Update session for next round
    local new_session
    new_session=$(extract_session_id "$raw_revised")
    [[ -n "$new_session" ]] && claude_session="$new_session"

    if [[ -z "$revised" ]]; then
      warn "Claude Code returned empty revision, keeping previous version"
    else
      current_content="$revised"
    fi

    save_artifact "round_${round}_claude_revised.md" "$current_content"
    ok "Claude Code produced revision"
  done

  # Max rounds reached
  echo ""
  warn "Reached maximum of ${MAX_ROUNDS} rounds without full approval."
  save_artifact "final.md" "$current_content"
  save_artifact "status.txt" "MAX_ROUNDS_REACHED at round $MAX_ROUNDS"
  log "Last version: ${CYAN}${SESSION_DIR}/final.md${NC}"
  return 1
}

# ─── CLI ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
cc-review: Automated Claude Code ↔ Codex review loop

Usage:
  cc-review plan <prompt>                    Generate and review a development plan
  cc-review code <prompt>                    Generate and review code
  cc-review plan --file <path> [prompt]      Review an existing plan file
  cc-review code --file <path> [prompt]      Review an existing code file

Options:
  --max-rounds <n>     Maximum review cycles (default: 5)
  --claude-model <m>   Claude model override
  --codex-model <m>    Codex model (default: o3)
  --output-dir <dir>   Output directory (default: .cc-review)
  --timeout <secs>     Timeout per CLI call in seconds (default: 300)
  --verbose            Show debug output
  --help               Show this help

Environment variables:
  CC_REVIEW_MAX_ROUNDS    CC_REVIEW_CLAUDE_MODEL    CC_REVIEW_CODEX_MODEL
  CC_REVIEW_OUTPUT_DIR    CC_REVIEW_VERBOSE          CC_REVIEW_TIMEOUT

Examples:
  cc-review plan "Build a REST API for user management with JWT auth"
  cc-review code "Implement a rate limiter middleware for Express"
  cc-review code --file src/auth.ts "Refactor to use passport.js"
  CC_REVIEW_MAX_ROUNDS=10 cc-review plan "Design a microservices architecture"
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local mode="" prompt="" target_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      plan|code)
        mode="$1"
        shift
        ;;
      --file)
        target_file="$2"
        shift 2
        ;;
      --max-rounds)
        MAX_ROUNDS="$2"
        shift 2
        ;;
      --claude-model)
        CLAUDE_MODEL="$2"
        shift 2
        ;;
      --codex-model)
        CODEX_MODEL="$2"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$prompt" ]]; then
          prompt="$1"
        else
          prompt="$prompt $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$mode" ]]; then
    err "Specify mode: plan or code"
    usage
    exit 1
  fi

  if [[ -z "$prompt" && -z "$target_file" ]]; then
    err "Provide a prompt or --file"
    usage
    exit 1
  fi

  # Default prompt when only --file is given
  if [[ -z "$prompt" && -n "$target_file" ]]; then
    prompt="Review and improve this ${mode}"
  fi

  check_deps
  run_review_loop "$mode" "$prompt" "$target_file"
}

main "$@"
