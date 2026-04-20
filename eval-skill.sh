#!/bin/bash
# eval-skill.sh — LLM-judged evaluation of skill quality (parallel execution)
#
# Two-pass evaluation per scenario (runs scenarios in parallel):
#   1. Sends eval prompt to Claude with the skill loaded
#   2. A judge scores whether the response meets assertions
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
#   PARALLEL      Max parallel evals (default: 4)
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
PARALLEL="${PARALLEL:-4}"
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

    local timeout_cmd=""
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout"
    fi

    if [[ -n "$timeout_cmd" ]]; then
        $timeout_cmd "$TIMEOUT" $CLAUDE_CMD --print \
            --model "$MODEL" \
            --max-turns 8 \
            -p "$(cat "$prompt_file")" > "$output_file" 2>/dev/null || true
    else
        $CLAUDE_CMD --print \
            --model "$MODEL" \
            --max-turns 8 \
            -p "$(cat "$prompt_file")" > "$output_file" 2>/dev/null || true
    fi
}

# Run a single eval scenario (both passes). Called as a subprocess.
# Writes result to $RESULTS_DIR/eval${eval_id}_result.txt
run_single_eval() {
    local skill_file="$1"
    local eval_file="$2"
    local eval_index="$3"
    local results_dir="$4"

    local skill_content
    skill_content=$(cat "$skill_file")

    local eval_id eval_prompt assertions_json assertion_count
    eval_id=$(json_get "$eval_file" "evals.$eval_index.id")
    eval_prompt=$(json_get "$eval_file" "evals.$eval_index.prompt")
    assertions_json=$(json_get "$eval_file" "evals.$eval_index.assertions")
    assertion_count=$(python3 -c "
import json
data = json.load(open('$eval_file'))
print(len(data['evals'][$eval_index]['assertions']))
" 2>/dev/null || echo 0)

    local response_file="$results_dir/eval${eval_id}_response.txt"
    local prompt_file="$results_dir/eval${eval_id}_prompt.txt"
    local judge_file="$results_dir/eval${eval_id}_judge.txt"
    local judge_prompt_file="$results_dir/eval${eval_id}_judge_prompt.txt"
    local result_file="$results_dir/eval${eval_id}_result.txt"

    # ── Pass 1: Run the skill ──
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
    local response
    response=$(cat "$response_file")

    # ── Pass 2: Judge assertions ──
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
    local judge_output
    judge_output=$(cat "$judge_file")

    # ── Parse results ──
    local eval_passed=0 eval_failed=0
    local fail_details=""

    while IFS='|' read -r verdict assertion reason; do
        verdict=$(echo "$verdict" | tr -d '[:space:]')
        case "$verdict" in
            PASS) ((eval_passed++)) ;;
            FAIL)
                ((eval_failed++))
                fail_details="${fail_details}FAIL|${assertion}|${reason}\n"
                ;;
        esac
    done <<< "$judge_output"

    local scored=$((eval_passed + eval_failed))
    if [[ $scored -eq 0 ]]; then
        eval_failed=$assertion_count
        fail_details="WARN|Judge returned no parseable results|\n"
    fi

    # Write result file: eval_id|prompt|passed|failed|scored|fail_details
    echo "${eval_id}|${eval_prompt}|${eval_passed}|${eval_failed}|${scored}|${fail_details}" > "$result_file"
}

# Export functions and vars for subprocesses
export -f run_single_eval run_claude json_get json_array_len
export CLAUDE_CMD MODEL DRY_RUN VERBOSE TIMEOUT

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
echo "Model: $MODEL | Timeout: ${TIMEOUT}s | Parallel: $PARALLEL"
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

    eval_count=$(json_array_len "$eval_file" "evals")

    RESULTS_DIR="$RESULTS_BASE/$skill_name"
    mkdir -p "$RESULTS_DIR"

    # Build list of eval indices to run
    eval_indices=()
    for ((i=0; i<eval_count; i++)); do
        eval_id=$(json_get "$eval_file" "evals.$i.id")
        if [[ -n "$TARGET_EVAL" && "$eval_id" != "$TARGET_EVAL" ]]; then
            continue
        fi
        eval_indices+=("$i")
    done

    if [[ ${#eval_indices[@]} -eq 0 ]]; then
        echo -e "${DIM}SKIP $skill_name — no matching evals${NC}"
        continue
    fi

    echo -e "${BLUE}Evaluating: $skill_name (${#eval_indices[@]} scenarios, $PARALLEL in parallel)${NC}"
    echo ""

    # ── Launch evals in parallel ──
    pids=()
    running=0

    for idx in "${eval_indices[@]}"; do
        eval_id=$(json_get "$eval_file" "evals.$idx.id")
        eval_prompt=$(json_get "$eval_file" "evals.$idx.prompt")
        echo -e "  ${DIM}#$eval_id: ${eval_prompt:0:70}... [launching]${NC}"

        run_single_eval "$skill_file" "$eval_file" "$idx" "$RESULTS_DIR" &
        pids+=("$!:$idx")
        ((running++))

        # Throttle: wait if we hit the parallel limit
        if [[ $running -ge $PARALLEL ]]; then
            # Wait for any one to finish
            wait -n 2>/dev/null || true
            ((running--))
        fi
    done

    # Wait for all remaining
    wait 2>/dev/null || true

    # ── Collect results ──
    echo ""
    skill_passed=0
    skill_failed=0
    report_lines=()
    report_lines+=("# Eval Report: $skill_name")
    report_lines+=("")
    report_lines+=("- **Date:** $(date -u '+%Y-%m-%d %H:%M UTC')")
    report_lines+=("- **Model:** $MODEL")
    report_lines+=("- **Parallel:** $PARALLEL")
    report_lines+=("")
    report_lines+=("| # | Scenario | Result | Score |")
    report_lines+=("| - | -------- | ------ | ----- |")

    for idx in "${eval_indices[@]}"; do
        eval_id=$(json_get "$eval_file" "evals.$idx.id")
        result_file="$RESULTS_DIR/eval${eval_id}_result.txt"

        if [[ ! -f "$result_file" ]]; then
            echo -e "  ${RED}#$eval_id: ERROR — no result file${NC}"
            ((skill_failed++))
            continue
        fi

        IFS='|' read -r r_id r_prompt r_passed r_failed r_scored r_details < "$result_file"

        if [[ "$r_failed" -eq 0 ]]; then
            echo -e "  ${GREEN}#$r_id: PASS ($r_passed/$r_scored)${NC}"
            ((skill_passed++))
        else
            echo -e "  ${RED}#$r_id: FAIL ($r_passed/$r_scored passed, $r_failed failed)${NC}"
            # Print fail details
            echo -e "$r_details" | while IFS='|' read -r fv fa fr; do
                fv=$(echo "$fv" | tr -d '[:space:]')
                [[ "$fv" == "FAIL" || "$fv" == "WARN" ]] && echo -e "    ${RED}$fv${NC} $fa ${DIM}$fr${NC}"
            done
            ((skill_failed++))
        fi
        report_lines+=("| $r_id | ${r_prompt:0:50}... | $([ "$r_failed" -eq 0 ] && echo PASS || echo FAIL) | $r_passed/$r_scored |")

        ((total_evals++))
    done

    # Skill summary
    total_skill=$((skill_passed + skill_failed))
    echo ""
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
