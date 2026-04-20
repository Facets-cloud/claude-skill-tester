#!/bin/bash
# eval-skill.sh — LLM-judged evaluation of skill quality
#
# Two-pass evaluation:
#   1. Sends each eval prompt to Claude with the skill loaded
#   2. A judge scores whether the response meets each assertion
#
# Usage:
#   ./eval-skill.sh /path/to/skills/                  # Eval all skills
#   ./eval-skill.sh /path/to/skills/my-skill/          # Eval one skill
#   ./eval-skill.sh /path/to/skills/my-skill/ 3        # Eval scenario #3 only
#   DRY_RUN=1 ./eval-skill.sh /path/to/skills/         # Show what would run
#
# Environment:
#   CLAUDE_CMD    Override claude binary (default: claude)
#   MODEL         Override model (default: sonnet)
#   DRY_RUN       Set to 1 to print prompts without running
#   VERBOSE       Set to 1 for full response output
#   TIMEOUT       Seconds per eval (default: 180)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
MODEL="${MODEL:-sonnet}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
TIMEOUT="${TIMEOUT:-180}"

TARGET="${1:-.}"
TARGET_EVAL="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_BASE="${EVAL_RESULTS_DIR:-./eval-results}"

mkdir -p "$RESULTS_BASE"

# ─── Helpers ───────────────────────────────────────────────

json_get() {
    python3 -c "
import json, sys
data = json.load(open('$1'))
path = '$2'.split('.')
obj = data
for p in path:
    if p.isdigit():
        obj = obj[int(p)]
    else:
        obj = obj[p]
if isinstance(obj, list):
    print(json.dumps(obj))
else:
    print(obj)
" 2>/dev/null
}

json_array_len() {
    python3 -c "
import json
data = json.load(open('$1'))
path = '$2'.split('.')
obj = data
for p in path:
    if p.isdigit():
        obj = obj[int(p)]
    else:
        obj = obj[p]
print(len(obj))
" 2>/dev/null
}

run_claude() {
    local prompt_file="$1"
    local output_file="$2"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[DRY RUN] Would send prompt ($(wc -c < "$prompt_file") chars)" > "$output_file"
        return 0
    fi

    if command -v gtimeout &>/dev/null; then
        TIMEOUT_CMD="gtimeout"
    elif command -v timeout &>/dev/null; then
        TIMEOUT_CMD="timeout"
    else
        TIMEOUT_CMD=""
    fi

    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$TIMEOUT" $CLAUDE_CMD --print \
            --model "$MODEL" \
            --max-turns 3 \
            -p "$(cat "$prompt_file")" > "$output_file" 2>/dev/null || true
    else
        $CLAUDE_CMD --print \
            --model "$MODEL" \
            --max-turns 3 \
            -p "$(cat "$prompt_file")" > "$output_file" 2>/dev/null || true
    fi
}

# ─── Discover skills ──────────────────────────────────────

skill_dirs=()
if [[ -f "$TARGET/SKILL.md" ]]; then
    skill_dirs+=("$TARGET")
elif [[ -d "$TARGET" ]]; then
    for d in "$TARGET"/*/; do
        [ -f "$d/SKILL.md" ] && skill_dirs+=("$d")
    done
fi

if [[ ${#skill_dirs[@]} -eq 0 ]]; then
    echo "No skills found at $TARGET"
    exit 1
fi

# ─── Main ──────────────────────────────────────────────────

echo "Skill Evaluation"
echo "======================================================"
echo "Model: $MODEL | Timeout: ${TIMEOUT}s"
[[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}DRY RUN — no LLM calls${NC}"
echo ""

total_evals=0
total_passed=0
total_failed=0

for skill_dir in "${skill_dirs[@]}"; do
    skill_name=$(basename "$skill_dir")
    eval_file="$skill_dir/evals/evals.json"
    skill_file="$skill_dir/SKILL.md"

    if [[ ! -f "$eval_file" ]]; then
        echo -e "${DIM}SKIP $skill_name — no evals/evals.json${NC}"
        continue
    fi

    skill_content=$(cat "$skill_file")
    eval_count=$(json_array_len "$eval_file" "evals")

    RESULTS_DIR="$RESULTS_BASE/$skill_name"
    mkdir -p "$RESULTS_DIR"

    echo -e "${BLUE}Evaluating: $skill_name ($eval_count scenarios)${NC}"
    echo ""

    skill_passed=0
    skill_failed=0
    report_lines=()
    report_lines+=("# Eval Report: $skill_name")
    report_lines+=("")
    report_lines+=("- **Date:** $(date -u '+%Y-%m-%d %H:%M UTC')")
    report_lines+=("- **Model:** $MODEL")
    report_lines+=("")
    report_lines+=("| # | Scenario | Result | Score |")
    report_lines+=("| - | -------- | ------ | ----- |")

    for ((i=0; i<eval_count; i++)); do
        eval_id=$(json_get "$eval_file" "evals.$i.id")
        eval_prompt=$(json_get "$eval_file" "evals.$i.prompt")

        [[ -n "$TARGET_EVAL" && "$eval_id" != "$TARGET_EVAL" ]] && continue

        assertions_json=$(json_get "$eval_file" "evals.$i.assertions")
        assertion_count=$(python3 -c "
import json
data = json.load(open('$eval_file'))
print(len(data['evals'][$i]['assertions']))
" 2>/dev/null || echo 0)

        echo -e "  #$eval_id: ${DIM}${eval_prompt:0:70}...${NC}"

        # ── Pass 1: Run the skill ──
        response_file="$RESULTS_DIR/eval${eval_id}_response.txt"
        prompt_file="$RESULTS_DIR/eval${eval_id}_prompt.txt"

        cat > "$prompt_file" << SKILLEOF
You are an AI assistant with the following skill loaded:

---SKILL START---
$skill_content
---SKILL END---

The user says:
$eval_prompt

Respond as the skill instructs. Since you cannot actually run commands, describe exactly what you WOULD do — what commands you'd run, what you'd look for, what your reasoning and output would be.
SKILLEOF

        run_claude "$prompt_file" "$response_file"
        response=$(cat "$response_file")

        [[ "$VERBOSE" == "1" ]] && echo -e "    ${DIM}Response: ${#response} chars${NC}"

        # ── Pass 2: Judge assertions ──
        judge_file="$RESULTS_DIR/eval${eval_id}_judge.txt"
        judge_prompt_file="$RESULTS_DIR/eval${eval_id}_judge_prompt.txt"

        cat > "$judge_prompt_file" << JUDGEEOF
You are an eval judge. Score whether a skill response meets each assertion.

RESPONSE TO EVALUATE:
$response

ASSERTIONS TO CHECK:
$assertions_json

For each assertion, output exactly one line:
PASS|<assertion text>|<brief reason>
or
FAIL|<assertion text>|<brief reason>

Output ONLY scored lines. One per assertion. Nothing else.
JUDGEEOF

        run_claude "$judge_prompt_file" "$judge_file"
        judge_output=$(cat "$judge_file")

        # ── Parse results ──
        eval_passed=0
        eval_failed=0

        while IFS='|' read -r verdict assertion reason; do
            verdict=$(echo "$verdict" | tr -d '[:space:]')
            case "$verdict" in
                PASS)
                    ((eval_passed++))
                    [[ "$VERBOSE" == "1" ]] && echo -e "    ${GREEN}PASS${NC} $assertion"
                    ;;
                FAIL)
                    ((eval_failed++))
                    echo -e "    ${RED}FAIL${NC} $assertion"
                    [[ -n "${reason:-}" ]] && echo -e "         ${DIM}$reason${NC}"
                    ;;
            esac
        done <<< "$judge_output"

        scored=$((eval_passed + eval_failed))
        if [[ $scored -eq 0 ]]; then
            echo -e "    ${YELLOW}WARN: Judge returned no parseable results${NC}"
            eval_failed=$assertion_count
        fi

        if [[ $eval_failed -eq 0 ]]; then
            echo -e "  ${GREEN}  PASS ($eval_passed/$scored)${NC}"
            ((skill_passed++))
        else
            echo -e "  ${RED}  FAIL ($eval_passed/$scored passed, $eval_failed failed)${NC}"
            ((skill_failed++))
        fi
        report_lines+=("| $eval_id | ${eval_prompt:0:50}... | $([ $eval_failed -eq 0 ] && echo PASS || echo FAIL) | $eval_passed/$scored |")

        ((total_evals++))
        echo ""
    done

    # Skill summary
    total_skill=$((skill_passed + skill_failed))
    if [[ $skill_failed -eq 0 ]]; then
        echo -e "${GREEN}  $skill_name: ALL PASSED ($skill_passed/$total_skill)${NC}"
    else
        echo -e "${RED}  $skill_name: $skill_failed FAILED, $skill_passed passed${NC}"
    fi
    ((total_passed += skill_passed))
    ((total_failed += skill_failed))

    # Write report
    if [[ -z "$TARGET_EVAL" ]]; then
        report_lines+=("" "**Result: $skill_passed passed, $skill_failed failed out of $total_skill**")
        printf '%s\n' "${report_lines[@]}" > "$RESULTS_DIR/report.md"
        echo "  Report: $RESULTS_DIR/report.md"
    fi
    echo ""
done

# ── Summary ──
echo "======================================================"
echo "  Total: $total_evals evals"
echo -e "  ${GREEN}Passed: $total_passed${NC}"
[[ $total_failed -gt 0 ]] && echo -e "  ${RED}Failed: $total_failed${NC}"

score=0
total=$((total_passed + total_failed))
[[ $total -gt 0 ]] && score=$(python3 -c "print(round($total_passed / $total * 100, 1))" 2>/dev/null || echo "0")
echo "  Score: ${score}%"
echo ""
echo "Results: $RESULTS_BASE/"

[[ $total_failed -eq 0 ]] && exit 0 || exit 1
