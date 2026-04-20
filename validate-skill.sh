#!/bin/bash
# validate-skill.sh — Structural validation of skill files
# No LLM required — pure bash checks against the skill spec
#
# Usage:
#   ./validate-skill.sh /path/to/skills/           # Validate all skills in directory
#   ./validate-skill.sh /path/to/skills/my-skill/   # Validate one skill

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET="${1:-.}"
ISSUES=0
WARNINGS=0
PASSED=0

# Determine if target is a single skill or a directory of skills
skill_dirs=()
if [[ -f "$TARGET/SKILL.md" ]]; then
    skill_dirs+=("$TARGET")
elif [[ -d "$TARGET" ]]; then
    for d in "$TARGET"/*/; do
        [ -f "$d/SKILL.md" ] && skill_dirs+=("$d")
    done
fi

if [[ ${#skill_dirs[@]} -eq 0 ]]; then
    echo "No skills found. Provide a path to a skill directory or a parent directory containing skills."
    echo "A skill directory must contain a SKILL.md file."
    exit 1
fi

echo "Validating ${#skill_dirs[@]} skill(s)"
echo "======================================================"
echo ""

for skill_dir in "${skill_dirs[@]}"; do
    skill_name=$(basename "$skill_dir")
    skill_file="$skill_dir/SKILL.md"
    skill_errors=()
    skill_warnings=()

    # Extract frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/p' "$skill_file" | sed '1d;$d')

    if [[ -z "$frontmatter" ]]; then
        echo -e "${RED}FAIL $skill_name${NC}"
        echo "   Missing YAML frontmatter (---)"
        ((ISSUES++))
        continue
    fi

    # Title
    title=$(echo "$frontmatter" | grep "^title:" | sed 's/^title: //' | tr -d '"')
    [[ -z "$title" ]] && skill_errors+=("Missing 'title' in frontmatter")

    # Description
    description=$(echo "$frontmatter" | grep "^description:" | head -1 | sed 's/^description: //' | tr -d '"')
    if [[ -z "$description" ]]; then
        skill_errors+=("Missing 'description' in frontmatter")
    elif [[ ${#description} -gt 1024 ]]; then
        skill_errors+=("Description too long: ${#description} chars (max 1024)")
    fi

    # Triggers
    triggers=$(echo "$frontmatter" | grep "^triggers:" | head -1)
    [[ -z "$triggers" ]] && skill_warnings+=("Missing 'triggers' — skill may not auto-activate")

    # Version
    version=$(echo "$frontmatter" | grep "^version:" | head -1)
    [[ -z "$version" ]] && skill_warnings+=("Missing 'version' field")

    # Line count
    line_count=$(wc -l < "$skill_file" | tr -d ' ')
    [[ $line_count -gt 500 ]] && skill_warnings+=("SKILL.md is $line_count lines (recommended <500)")

    # Evals
    if [[ ! -f "$skill_dir/evals/evals.json" ]]; then
        skill_warnings+=("No evals — add evals/evals.json")
    else
        if ! python3 -m json.tool "$skill_dir/evals/evals.json" >/dev/null 2>&1; then
            skill_errors+=("evals/evals.json is not valid JSON")
        else
            eval_count=$(python3 -c "import json; d=json.load(open('$skill_dir/evals/evals.json')); print(len(d.get('evals',[])))" 2>/dev/null || echo 0)
            [[ "$eval_count" -lt 3 ]] && skill_warnings+=("Only $eval_count evals — recommend at least 6")
        fi
    fi

    # Report
    if [[ ${#skill_errors[@]} -gt 0 ]]; then
        echo -e "${RED}FAIL $skill_name${NC}"
        for e in "${skill_errors[@]}"; do echo -e "   ${RED}Error:${NC} $e"; done
        for w in "${skill_warnings[@]}"; do echo -e "   ${YELLOW}Warn:${NC} $w"; done
        ((ISSUES++))
    elif [[ ${#skill_warnings[@]} -gt 0 ]]; then
        echo -e "${YELLOW}WARN $skill_name${NC}"
        for w in "${skill_warnings[@]}"; do echo -e "   ${YELLOW}Warn:${NC} $w"; done
        ((WARNINGS++))
    else
        echo -e "${GREEN}PASS $skill_name${NC}"
        ((PASSED++))
    fi
done

echo ""
echo "======================================================"
echo -e "  ${GREEN}Passed: $PASSED${NC}"
[[ $WARNINGS -gt 0 ]] && echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
[[ $ISSUES -gt 0 ]] && echo -e "  ${RED}Failed: $ISSUES${NC}"

[[ $ISSUES -eq 0 ]] && exit 0 || exit 1
