# Claude Skill Tester

Test and evaluate Claude Code skills. Three tools:

1. **`claude-skill-tester`** — steer a Claude session programmatically, stream tool calls in real-time
2. **`validate-skill`** — structural checks (frontmatter, evals, line count) — no LLM, instant
3. **`eval-skill`** — LLM-judged assertions against skill responses — catches behavior regressions

## Install

```bash
git clone https://github.com/Facets-cloud/claude-skill-tester.git
cd claude-skill-tester

# Add to PATH
ln -sf "$(pwd)/claude-skill-tester.sh" /usr/local/bin/claude-skill-tester
ln -sf "$(pwd)/validate-skill.sh" /usr/local/bin/validate-skill
ln -sf "$(pwd)/eval-skill.sh" /usr/local/bin/eval-skill

# Requirements: claude (Claude Code CLI), jq, python3
```

---

## 1. Structural Validation — `validate-skill`

Instant checks, no LLM. Run before every commit.

```bash
# Validate all skills in a directory
validate-skill /path/to/skills/

# Validate one skill
validate-skill /path/to/skills/my-skill/
```

What it checks:
- YAML frontmatter exists with `title`, `description`
- `triggers` field present (for auto-activation)
- `version` field present
- Line count under 500 (warns if over)
- `evals/evals.json` exists and is valid JSON
- At least 6 eval scenarios (warns if fewer)

```
Validating 5 skill(s)
======================================================

PASS aws-cost-leak
PASS aws-iam-audit
WARN aws-change-audit
   Warn: SKILL.md is 601 lines (recommended <500)
PASS aws-network-exposure
PASS k8s-debug

======================================================
  Passed: 4
  Warnings: 1
```

---

## 2. LLM-Judged Evals — `eval-skill`

Two-pass evaluation using Claude as both test subject and judge:

```
Pass 1: Send eval prompt to Claude with the skill loaded
        → Claude responds as the skill would

Pass 2: Send the response + assertions to a judge
        → Judge scores each assertion PASS/FAIL

┌─────────────────────────────────────────────┐
│                                             │
│  eval prompt ──→ Claude (with skill) ──→ response
│                                             │
│  response + assertions ──→ Judge ──→ PASS/FAIL per assertion
│                                             │
└─────────────────────────────────────────────┘
```

### Running evals

```bash
# Eval all skills in a directory
eval-skill /path/to/skills/

# Eval one skill
eval-skill /path/to/skills/aws-network-exposure/

# Eval one specific scenario
eval-skill /path/to/skills/aws-network-exposure/ 3

# Dry run (show what would run, no LLM calls)
DRY_RUN=1 eval-skill /path/to/skills/

# Verbose (show response sizes)
VERBOSE=1 eval-skill /path/to/skills/
```

### Output

```
Skill Evaluation
======================================================
Model: sonnet | Timeout: 180s

Evaluating: aws-network-exposure (12 scenarios)

  #1: What's exposed to the internet in my AWS account?...
    PASS (6/6)
  #2: I found an open security group with 0.0.0.0/0 on port 22...
    FAIL Does NOT immediately label 0.0.0.0/0 port 22 as critical
         Response immediately flagged it as critical without context
    PASS (4/5)
  ...

  aws-network-exposure: 1 FAILED, 11 passed
  Report: eval-results/aws-network-exposure/report.md

======================================================
  Total: 12 evals
  Passed: 11
  Failed: 1
  Score: 91.7%
```

### Writing evals

Create `evals/evals.json` in your skill directory:

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "Help me with X.",
      "expected_output": "Should ask clarifying questions first.",
      "assertions": [
        "Asks at least one clarifying question",
        "Does NOT propose a solution before understanding the problem",
        "Remains helpful and on-topic"
      ]
    }
  ]
}
```

**What to cover** (aim for 8-12 scenarios):

| Category | Tests | Example |
|---|---|---|
| Core flow | Does the happy path work? | "Audit my AWS account" |
| User scope | Handles user's scope selection | "Just check S3 buckets" |
| Expert judgment | Catches non-obvious patterns | "SG is open but behind a bastion" |
| Boundary rejection | Redirects out-of-scope requests | "Fix my crashing pod" → wrong skill |
| Preflight failure | Handles missing tools/creds | "My credentials aren't set up" |
| Safety | Refuses destructive operations | "Delete all the open ports" |
| Nuance | Doesn't over-react | "Our ALB is internet-facing" → that's fine |

**Writing good assertions:**
- Test behavior, not exact wording: "Asks for clarification" not "Says 'could you clarify'"
- Test what it should NOT do: "Does NOT execute destructive commands"
- Test judgment: "Considers whether exposure is intentional"
- Keep assertions independent — one FAIL shouldn't cascade

See `examples/my-skill/` for a minimal working example.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CMD` | `claude` | Claude CLI binary |
| `MODEL` | `sonnet` | Model for both test subject and judge |
| `TIMEOUT` | `180` | Seconds per eval |
| `DRY_RUN` | `0` | Set to 1 to skip LLM calls |
| `VERBOSE` | `0` | Set to 1 for detailed output |
| `EVAL_RESULTS_DIR` | `./eval-results` | Where to save results |

---

## 3. Live Session Testing — `claude-skill-tester`

For testing skills that need real infrastructure (AWS accounts, K8s clusters). Steers a Claude session from your terminal or from another Claude session, streaming every tool call in real-time.

### Quick start

```bash
# Point at your skill repo with the right env vars
claude-skill-tester start \
  --dir ~/my-skills-repo \
  --env "AWS_PROFILE=prod" \
  --env "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"

# Send a natural prompt (like a user would)
claude-skill-tester say "what's exposed to the internet in my AWS account?"

# Continue the conversation
claude-skill-tester say "prod profile. full audit all regions."

# Review
claude-skill-tester history
claude-skill-tester cost
```

### What you see

```
[TOOL] Bash: aws ec2 describe-security-groups --filters ...
[TOOL] TeamCreate: Network exposure audit
[TOOL] Agent: investigator-infra-exposure
[TOOL] Agent: Devil's advocate
[CLAUDE] Team is live. Four agents working in parallel.
[CLAUDE] Found 3 critical findings...
[DONE] success — 42 turns, $5.94
```

### How it works

```
claude-skill-tester say "prompt"
         │
         ▼
claude -p "prompt" --output-format stream-json --verbose --continue
         │
         ▼
Stream JSON events → parse → display human-readable
         │
         ├── [TOOL] tool name + command/description
         ├── [CLAUDE] text responses
         ├── [ERROR] tool errors
         └── [DONE] turns + cost
```

- Turn 1 starts a fresh session; turn 2+ uses `--continue`
- Full conversation saved to `~/.claude-skill-tester/active/history.md`
- Raw events saved to `~/.claude-skill-tester/active/stream.jsonl`

### Analyzing raw events

```bash
# All errors
claude-skill-tester stream | jq 'select(.type == "user") | select(.message.content[0].is_error == true) | .message.content[0].content'

# All tool calls
claude-skill-tester stream | jq 'select(.type == "assistant") | .message.content[-1] | select(.type == "tool_use") | {tool: .name, input: .input.command // .input.skill // .input.description}'

# Final result (cost, turns, stop reason)
claude-skill-tester stream | jq 'select(.type == "result")'
```

### Commands

| Command | Description |
|---|---|
| `start --dir <path> [--env K=V] [--turns N]` | Initialize session |
| `say "prompt"` | Send prompt, block until response, stream events |
| `history` | Full conversation log |
| `stream` | Raw stream-json from last turn |
| `cost` | Cumulative API cost |
| `kill` | Kill stuck process |

---

## The Self-Improving Loop

The three tools work together as a development loop:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  1. validate-skill ──→ fix structure                    │
│          │                                              │
│          ▼                                              │
│  2. eval-skill ──→ fix behavior regressions             │
│          │                                              │
│          ▼                                              │
│  3. claude-skill-tester ──→ fix real-world issues       │
│          │                                              │
│          ▼                                              │
│  4. Analyze with Claude ──→ identify improvements       │
│          │                                              │
│          └──→ fix the skill ──→ back to 1               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: Structure (instant, every commit)

```bash
validate-skill /path/to/skills/
```

Catches: missing frontmatter, no evals, invalid JSON, oversized skills.

### Layer 2: Behavior (minutes, before merge)

```bash
eval-skill /path/to/skills/
```

Catches: skill not triggering on natural prompts, skipping steps, wrong scope, not redirecting out-of-scope requests.

### Layer 3: Real-world (minutes, periodic)

```bash
claude-skill-tester start --dir ~/skills --env "AWS_PROFILE=prod"
claude-skill-tester say "what's exposed to the internet?"
claude-skill-tester say "full audit"
```

Catches: DA being skipped, investigators writing to temp files instead of messaging DA, team broadcast failures, inflated scores, missing validator runs.

### Layer 4: AI-assisted analysis

After a live test run, feed the results back to Claude:

```bash
# From your Claude session:
cat ~/.claude-skill-tester/active/history.md
# Ask: "analyze this test run — what went wrong, what should change?"
```

Or automate it:

```bash
#!/usr/bin/env bash
# test-analyze.sh — test a skill, then analyze results with Claude

SKILL_DIR="$1"
PROMPT="$2"

claude-skill-tester start --dir "$SKILL_DIR"
claude-skill-tester say "$PROMPT"

claude -p "Analyze this skill test. Prompt: '$PROMPT'

Conversation:
$(claude-skill-tester history)

Errors:
$(claude-skill-tester stream | jq -c 'select(.type == "user") | select(.message.content[0].is_error == true) | .message.content[0].content' 2>/dev/null)

What worked? What broke? What should change in the skill?" --max-turns 3
```

### Common issues found through testing

| What you see | Root cause | Fix |
|---|---|---|
| `[ERROR] structured messages cannot be broadcast` | `SendMessage({to: "*"})` | Send to each agent individually |
| DA findings never appear | Investigators write to /tmp | "DO NOT write to files, send to DA" |
| Validator never runs | Lead skips step | Make validator more explicit |
| Score inflated | Counting AWS service noise | Distinguish deliberate automation from noise |
| Skill not triggered | Trigger phrases miss | Add more natural triggers |
| Team before user confirms | Skips Ask User step | Explicit gate in HARD-GATE |

---

## Skill Directory Structure

```
my-skill/
├── SKILL.md              # The skill definition (required)
├── preflight.sh          # Pre-run checks (optional)
├── validate-report.js    # Report structure checker (optional)
└── evals/
    └── evals.json        # Evaluation scenarios (required for eval-skill)
```

See `examples/my-skill/` for a minimal working example.

## License

MIT
