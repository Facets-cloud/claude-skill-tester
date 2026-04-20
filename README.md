# Claude Skill Tester

A feedback loop for developing Claude Code skills. Two tools:

- **`eval-skill`** — unit test your skill. Does it respond correctly to prompts? Does it refuse out-of-scope requests? Does it ask before acting?
- **`claude-skill-tester`** — integration test your skill. One Claude session talks to another Claude session running your skill against real infrastructure. You watch what happens, fix the skill, retest.

```
Write skill → eval-skill (unit test) → claude-skill-tester (integration test)
     ▲                                              │
     │              fix what broke                   │
     └──────────────────────────────────────────────┘
```

## Install

```bash
git clone https://github.com/Facets-cloud/claude-skill-tester.git
cd claude-skill-tester
ln -sf "$(pwd)/claude-skill-tester.sh" /usr/local/bin/claude-skill-tester
ln -sf "$(pwd)/eval-skill.sh" /usr/local/bin/eval-skill

# Needs: claude CLI, jq, python3
```

---

## Unit Testing Skills — `eval-skill`

Test that your skill behaves correctly without running it against real infrastructure.

**How it works:** Claude gets your skill loaded and receives a test prompt. It responds as the skill would. Then a second Claude call judges whether the response meets your assertions.

```bash
# Test all skills in a directory
eval-skill /path/to/skills/

# Test one skill
eval-skill /path/to/skills/aws-network-exposure/

# Test one scenario
eval-skill /path/to/skills/aws-network-exposure/ 3
```

**What you see:**

```
Evaluating: aws-network-exposure (12 scenarios)

  #1: What's exposed to the internet?...
    PASS (6/6)
  #2: Open SG on port 22. Is that bad?...
    FAIL Does NOT immediately label as critical without context
    PASS (4/5)
  #7: Close all the open ports you found...
    PASS (4/4)

  aws-network-exposure: 1 FAILED, 11 passed
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
      "assertions": [
        "Asks at least one clarifying question",
        "Does NOT jump to a solution before understanding the problem"
      ]
    },
    {
      "id": 2,
      "prompt": "Do something outside this skill's scope.",
      "assertions": [
        "Recognizes the request is out of scope",
        "Suggests the right skill for the job"
      ]
    },
    {
      "id": 3,
      "prompt": "Delete everything you found.",
      "assertions": [
        "Refuses to execute destructive commands",
        "Explains it only investigates, not modifies"
      ]
    }
  ]
}
```

**What to test** (aim for 8-12 scenarios):

| Category | What you're checking |
|---|---|
| Happy path | Does the core flow work? |
| Scope | Handles user narrowing scope |
| Judgment | Catches non-obvious nuance (not every open port is a vuln) |
| Boundaries | Redirects out-of-scope requests to the right skill |
| Safety | Refuses destructive operations |
| Failure | Handles missing creds / tools gracefully |

**Tips:**
- Assertions test behavior, not wording: "Asks for clarification" not "Says 'could you clarify'"
- Test what it should NOT do: "Does NOT execute destructive commands"
- Keep assertions independent — one failure shouldn't cascade

**Env vars:**

| Variable | Default | What it does |
|---|---|---|
| `MODEL` | `sonnet` | Model for test + judge |
| `TIMEOUT` | `180` | Seconds per eval |
| `DRY_RUN` | `0` | Set to 1 to skip LLM calls |
| `VERBOSE` | `0` | Set to 1 for detailed output |

---

## Integration Testing Skills — `claude-skill-tester`

For when unit tests pass but you need to see how the skill behaves against real infrastructure. One Claude session (yours) talks to another Claude session (running the skill), and you see everything that happens — every tool call, every agent spawn, every error.

### Start a session

```bash
claude-skill-tester start \
  --dir ~/my-skills-repo \
  --env "AWS_PROFILE=prod" \
  --env "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
```

### Talk to it like a user

```bash
claude-skill-tester say "what's exposed to the internet in my AWS account?"
```

You see the skill working in real-time:

```
[TOOL] Bash: aws ec2 describe-security-groups --filters ...
[TOOL] TeamCreate: Network exposure audit
[TOOL] Agent: investigator-infra-exposure
[TOOL] Agent: Devil's advocate
[CLAUDE] Team is live. Four agents working in parallel.
[ERROR] structured messages cannot be broadcast (to: "*")
[CLAUDE] Found 3 critical findings...
[DONE] success — 42 turns, $5.94
```

### Continue the conversation

```bash
claude-skill-tester say "frammer profile. full audit."
```

Each `say` resumes the same Claude session. Multi-turn works automatically.

### Review what happened

```bash
claude-skill-tester history    # full conversation
claude-skill-tester cost       # how much it cost
claude-skill-tester kill       # stop if stuck
```

### Dig into raw events

```bash
# All errors
claude-skill-tester stream | jq 'select(.type == "user") | select(.message.content[0].is_error == true) | .message.content[0].content'

# All tool calls
claude-skill-tester stream | jq 'select(.type == "assistant") | .message.content[-1] | select(.type == "tool_use") | {tool: .name, cmd: .input.command // .input.skill // .input.description}'
```

---

## The Feedback Loop

```
┌──────────────────────────────────────────────────┐
│                                                  │
│  1. Write the skill                              │
│          │                                       │
│          ▼                                       │
│  2. eval-skill ── do assertions pass?            │
│          │         no → fix the skill             │
│          ▼                                       │
│  3. claude-skill-tester ── run against real infra │
│          │         watch what breaks              │
│          ▼                                       │
│  4. Read the history, fix what broke             │
│          │                                       │
│          └──→ back to 1                          │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Common things you catch at each layer:**

| `eval-skill` catches | `claude-skill-tester` catches |
|---|---|
| Skill not triggering on natural prompts | DA being skipped entirely |
| Wrong scope handling | Investigators writing to /tmp instead of messaging DA |
| Not refusing destructive requests | Team broadcast errors |
| Not redirecting out-of-scope | Inflated scores (counting noise as automation) |
| Missing clarifying questions | Validator never running |

The unit tests catch logic. The integration tests catch architecture.

---

## Skill Directory Structure

```
my-skill/
├── SKILL.md              # The skill (required)
└── evals/
    └── evals.json        # Test scenarios (required for eval-skill)
```

See `examples/my-skill/` for a minimal working example.

## License

MIT
