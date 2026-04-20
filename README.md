# Claude Skill Tester

Test Claude Code skills using Claude. Install this as a skill, then ask Claude to test your other skills — it runs unit tests, spawns live integration sessions, and tells you what broke.

## Install

```bash
# As a Claude Code plugin (recommended)
claude /plugin add Facets-cloud/claude-skill-tester

# Or clone and symlink
git clone https://github.com/Facets-cloud/claude-skill-tester.git
mkdir -p ~/.claude/skills && ln -sf "$(pwd)/claude-skill-tester/SKILL.md" ~/.claude/skills/test-skill/SKILL.md
```

Requires: `claude` CLI, `jq`, `python3`

## What It Does

Once installed, you talk to Claude naturally:

> "Test my aws-network-exposure skill"

> "Run evals on the k8s-debug skill in ~/devops-skills/skills/k8s-debug/"

> "Integration test the cost-leak skill against our prod AWS account"

> "The DA keeps getting skipped — can you test why?"

Claude figures out what kind of testing you need and runs it.

## Two Kinds of Tests

### Unit Tests — "does the skill behave correctly?"

Claude loads your skill, sends test prompts to another Claude, and a judge checks whether the responses meet your assertions. No real infrastructure needed.

```
You: "run evals on my network-exposure skill"

Claude runs eval-skill.sh → 12 scenarios, 4 in parallel:

  #1  What's exposed to the internet?        PASS (6/6)
  #2  Open SG on port 22. Is that bad?       FAIL (4/5)
  #3  Are any S3 buckets public?             PASS (5/5)
  #6  Find unused resources (out of scope)   FAIL (2/4)
  ...
  Score: 10/12 passed (94.4%)

  Failures:
  - #2: Skill labels port 22 as critical without checking context
  - #6: Skill attempts cost optimization instead of redirecting
```

### Integration Tests — "does it work against real infrastructure?"

Claude spawns another Claude session with your skill loaded, real AWS/K8s credentials, and sends prompts as a user would. You see every tool call, agent spawn, and error streamed back.

```
You: "test the network-exposure skill against frammer's AWS account"

Claude starts a test session and streams what happens:

  [TOOL] Bash: bash preflight.sh aws-network-exposure
  [CLAUDE] Preflight passed. Found EKS cluster.
  [TOOL] TeamCreate: Network exposure audit
  [TOOL] Agent: investigator-infra-exposure
  [TOOL] Agent: Devil's advocate
  [CLAUDE] Team is live. Four agents working.
  ...
  [CLAUDE] Score: 38/100. 3 critical findings.
  [DONE] 42 turns, $5.94

Claude then reads the conversation history and tells you:
  - DA review was skipped (investigators wrote to /tmp instead of messaging DA)
  - Validator never ran
  - Survey wasn't shown to user before spawning team
```

## The Feedback Loop

```
Write skill
    │
    ▼
"run evals on my skill" ── pass? ── no → Claude tells you what failed, you fix
    │ yes
    ▼
"integration test against prod" ── works? ── no → Claude analyzes the stream, you fix
    │ yes
    ▼
ship it
```

This is how every skill in [devops-skills](https://github.com/Facets-cloud/devops-skills) was built and tested.

## Writing Evals for Your Skill

Create `evals/evals.json` next to your `SKILL.md`:

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "A natural prompt that should trigger the skill",
      "assertions": [
        "Does the right thing",
        "Does NOT do the wrong thing"
      ]
    }
  ]
}
```

Aim for 8-12 scenarios covering:

| | |
|---|---|
| **Happy path** | Does the core flow work? |
| **Judgment** | Catches nuance (not every open port is a vuln) |
| **Boundaries** | Redirects out-of-scope requests |
| **Safety** | Refuses destructive operations |
| **Failure** | Handles missing creds / tools gracefully |

Assertions test behavior, not wording. "Asks for clarification" not "Says 'could you clarify'".

See `examples/my-skill/` for a minimal working example.

## License

MIT
