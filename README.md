# Claude Skill Tester

Test Claude Code skills using Claude. Install this as a plugin, then ask Claude to test your skills — it runs unit tests, spawns live sessions against real infrastructure, analyzes what broke, and fixes the skill.

## Install

```bash
# As a Claude Code plugin
claude /plugin add Facets-cloud/claude-skill-tester
```

That's it. Claude now has a `test-skill` skill that knows how to use `eval-skill.sh` and `claude-skill-tester.sh`.

## How It Works

You're developing skills in some directory. You tell Claude:

> "Run evals on my aws-network-exposure skill"

Claude runs unit tests — sends test prompts to another Claude with your skill loaded, judges whether responses meet your assertions, and reports what passed and failed:

```
#1  What's exposed to the internet?        PASS (6/6)
#2  Open SG on port 22. Is that bad?       FAIL (4/5)
#6  Find unused resources (out of scope)   FAIL (2/4)

Score: 10/12 passed (94.4%)

Failures:
- #2: Skill labels port 22 as critical without checking context
- #6: Skill attempts cost optimization instead of redirecting
```

Claude reads the failures, opens the skill, fixes the behavior, and reruns.

> "Integration test the network-exposure skill against frammer's AWS account"

Claude spawns another Claude session with real AWS credentials, sends it prompts like a user would, and streams what happens:

```
[TOOL] Bash: bash preflight.sh aws-network-exposure
[TOOL] TeamCreate: Network exposure audit
[TOOL] Agent: investigator-infra-exposure
[TOOL] Agent: Devil's advocate
[CLAUDE] Team is live. Four agents working.
[ERROR] structured messages cannot be broadcast (to: "*")
[CLAUDE] Score: 38/100. 3 critical findings.
[DONE] 42 turns, $5.94
```

Claude reads the stream, spots that the DA was skipped and the broadcast failed, fixes the skill, and retests.

## The Loop

```
Write skill → Claude tests it → Claude fixes what broke → Claude retests
                                        │
                                        └──→ repeat until clean
```

Two layers of testing:

| Unit tests (eval-skill) | Integration tests (claude-skill-tester) |
|---|---|
| Does the skill respond correctly? | Does it work against real infra? |
| Does it refuse destructive requests? | Does the DA actually review findings? |
| Does it redirect out-of-scope? | Do teams spawn and communicate correctly? |
| Fast, no real infrastructure | Slower, needs real AWS/K8s credentials |

## Writing Evals

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

Aim for 8-12 scenarios. Test the happy path, nuance, boundaries, safety, and failure handling. Assertions test behavior, not exact wording.

See `examples/my-skill/` for a minimal example.

## License

MIT
