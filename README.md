# Claude Skill Tester

Test Claude Code skills by steering a Claude session programmatically. See every tool call, every response, every error — in real-time. Then use the conversation history to improve the skill and retest.

## Why

When you build a Claude Code skill, you need to test it against real infrastructure — real AWS accounts, real K8s clusters, real data. But skills run inside Claude sessions that are hard to observe from the outside. You can't see what tools Claude called, what errors it hit, or why the DA skipped a finding.

This tool solves that by running Claude in `--print` mode with `--output-format stream-json`, parsing every event, and showing you a live stream of what's happening:

```
[TOOL] Bash: aws ec2 describe-security-groups --filters ...
[TOOL] TeamCreate: Network exposure audit
[TOOL] Agent: investigator-infra-exposure
[CLAUDE] Found 3 security groups with 0.0.0.0/0...
[ERROR] structured messages cannot be broadcast (to: "*")
[TOOL] Agent: Devil's advocate
[CLAUDE] Team is live. Four agents working in parallel.
[DONE] success — 42 turns, $5.94
```

## Install

```bash
# Clone
git clone https://github.com/Facets-cloud/claude-skill-tester.git
cd claude-skill-tester

# Add to PATH (or symlink)
ln -sf "$(pwd)/claude-skill-tester.sh" /usr/local/bin/claude-skill-tester

# Requirements
# - claude (Claude Code CLI) — https://claude.ai/code
# - jq — brew install jq
```

## Quick Start

```bash
# 1. Point at your skill repo
claude-skill-tester start --dir ~/my-skills-repo --env "AWS_PROFILE=prod"

# 2. Send a natural prompt (like a user would)
claude-skill-tester say "what's exposed to the internet in my AWS account?"

# 3. Claude responds, asks for scope — continue the conversation
claude-skill-tester say "prod profile. full audit all regions."

# 4. Review the full conversation
claude-skill-tester history

# 5. Check the cost
claude-skill-tester cost
```

## How It Works

```
┌──────────────────────────────────┐
│  Your terminal / Claude session  │
│                                  │
│  claude-skill-tester say "..."   │
│         │                        │
│         ▼                        │
│  claude -p "..." \               │
│    --output-format stream-json \ │
│    --verbose \                   │
│    --continue                    │
│         │                        │
│         ▼                        │
│  Stream JSON events in real-time │
│  ┌─────────────────────────────┐ │
│  │ [TOOL] Bash: aws ec2 ...   │ │
│  │ [CLAUDE] Found 3 SGs...    │ │
│  │ [TOOL] TeamCreate          │ │
│  │ [TOOL] Agent: investigator │ │
│  │ [ERROR] broadcast failed   │ │
│  │ [DONE] 42 turns, $5.94     │ │
│  └─────────────────────────────┘ │
│                                  │
│  history.md ← full conversation  │
│  stream.jsonl ← raw events      │
└──────────────────────────────────┘
```

Key details:
- **Turn 1** starts a fresh Claude session
- **Turn 2+** uses `--continue` to resume the same session
- Events are streamed via `--output-format stream-json --verbose`
- Tool calls, text responses, and errors are parsed and displayed
- Full conversation saved to `~/.claude-skill-tester/active/history.md`
- Raw stream saved to `~/.claude-skill-tester/active/stream.jsonl`

## Testing a Skill — Step by Step

### 1. Set up the environment

```bash
claude-skill-tester start \
  --dir /path/to/your/skills/repo \
  --env "AWS_PROFILE=customer-prod" \
  --env "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" \
  --turns 80
```

The `--dir` must point to a directory where Claude can discover your skills (either via plugins or local skill files). Environment variables are exported before each `claude` call.

### 2. Prompt like a user

Don't tell Claude which skill to use. Prompt naturally:

```bash
# Good — natural user prompt
claude-skill-tester say "what's exposed to the internet in my AWS account?"

# Bad — prescriptive, tells Claude what to do
claude-skill-tester say "use the aws-network-exposure skill with profile frammer"
```

The skill should trigger from the natural prompt. If it doesn't, your skill's triggers need work.

### 3. Follow the conversation

Skills often ask for user input (profile selection, scope, confirmation). Continue the conversation:

```bash
claude-skill-tester say "prod profile. full audit all regions."
claude-skill-tester say "yes, include K8s"
```

### 4. Analyze what happened

```bash
# Full conversation
claude-skill-tester history

# Raw events (for debugging tool call issues)
claude-skill-tester stream | jq 'select(.type == "user" and .message.content[0].is_error == true)'

# Just errors
claude-skill-tester stream | jq 'select(.type == "user") | select(.message.content[0].is_error == true) | .message.content[0].content'

# Just tool calls
claude-skill-tester stream | jq 'select(.type == "assistant") | .message.content[-1] | select(.type == "tool_use") | {tool: .name, input: .input.command // .input.skill // .input.description}'

# Cost
claude-skill-tester cost
```

### 5. Fix and retest

Fix the skill based on what you observed, then test again:

```bash
claude-skill-tester kill          # clean up
claude-skill-tester start --dir ~/my-skills-repo --env "AWS_PROFILE=prod"
claude-skill-tester say "what's exposed to the internet?"
```

## The Self-Improving Loop

The real power is using Claude itself to analyze test results and improve skills. Here's the pattern:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│              The Self-Improving Loop                    │
│                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  1. Test  │───▶│2. Analyze│───▶│ 3. Fix   │          │
│  │  the skill│    │  output  │    │ the skill│          │
│  └──────────┘    └──────────┘    └──────────┘          │
│       ▲                                  │              │
│       │                                  │              │
│       └──────────────────────────────────┘              │
│                   repeat                                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Step 1: Test the skill

```bash
claude-skill-tester start --dir ~/devops-skills --env "AWS_PROFILE=frammer"
claude-skill-tester say "what's exposed to the internet in my AWS account?"
claude-skill-tester say "frammer. full audit."
```

### Step 2: Analyze with Claude

From your main Claude session, read the test output and ask Claude to analyze it:

```bash
# In your Claude session:
cat ~/.claude-skill-tester/active/history.md
# Then ask: "analyze this skill test run — what went wrong, what can be improved?"
```

Or use the raw stream for deeper analysis:

```bash
# Show all errors
cat ~/.claude-skill-tester/active/stream.jsonl | jq 'select(.type == "user") | select(.message.content[0].is_error == true)'

# Show the result event (cost, turns, stop reason)
cat ~/.claude-skill-tester/active/stream.jsonl | jq 'select(.type == "result")'
```

### Step 3: Fix the skill

Common issues found through testing:

| Symptom in stream | Root cause | Fix |
|---|---|---|
| `[ERROR] structured messages cannot be broadcast` | Skill uses `SendMessage({to: "*"})` | Send to each agent individually |
| DA findings never appear | Investigators write to /tmp instead of sending to DA | Add "DO NOT write to files, send to DA" |
| Validator never runs | Lead skips validate step | Make validator step more explicit |
| Score inflated | Counting AWS service noise as automation | Add tier classification guidance |
| Skill not triggered | Trigger phrases don't match user prompt | Add more natural trigger phrases |
| Team spawned before user confirms scope | Lead skips the Ask User step | Add explicit gate in HARD-GATE |

### Step 4: Retest

```bash
claude-skill-tester kill
claude-skill-tester start --dir ~/devops-skills --env "AWS_PROFILE=frammer"
claude-skill-tester say "what's exposed to the internet in my AWS account?"
```

Repeat until the skill runs clean.

### Automating the loop

You can script the entire test-analyze-fix cycle:

```bash
#!/usr/bin/env bash
# test-and-analyze.sh — run a skill test, then analyze results

SKILL_DIR="$1"
PROMPT="$2"

# Test
claude-skill-tester start --dir "$SKILL_DIR"
claude-skill-tester say "$PROMPT"

# Analyze (in a separate Claude session)
claude -p "$(cat << EOF
Analyze this skill test run. The skill was tested with prompt: "$PROMPT"

Conversation history:
$(cat ~/.claude-skill-tester/active/history.md)

Errors from stream:
$(cat ~/.claude-skill-tester/active/stream.jsonl | jq -c 'select(.type == "user") | select(.message.content[0].is_error == true) | .message.content[0].content' 2>/dev/null)

Result:
$(cat ~/.claude-skill-tester/active/stream.jsonl | jq -c 'select(.type == "result")' 2>/dev/null | tail -1)

What went well? What broke? What should change in the skill?
EOF
)" --max-turns 3
```

## Commands Reference

| Command | Description |
|---|---|
| `start --dir <path> [--env K=V] [--turns N]` | Initialize a test session |
| `say "prompt"` | Send a prompt, block until response, stream events |
| `history` | Show full conversation (markdown) |
| `stream` | Show raw stream-json events from last turn |
| `cost` | Show cumulative API cost |
| `kill` | Kill a stuck Claude process |

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_SKILL_TESTER_HOME` | `~/.claude-skill-tester` | State directory |

## State Files

```
~/.claude-skill-tester/active/
├── history.md       # Full conversation (user + claude turns)
├── stream.jsonl     # Raw stream-json events from last turn
├── workdir          # Current working directory
├── env              # Environment variables (one per line)
├── tools            # Allowed tools list
├── max_turns        # Max turns per say
├── turn             # Current turn number
├── total_cost       # Last reported cost
└── pid              # PID of running claude process (if any)
```

## License

MIT
