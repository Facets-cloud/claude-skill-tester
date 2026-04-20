---
title: "Skill Tester"
description: "Test and improve Claude Code skills. Unit test with eval-skill (LLM-judged assertions). Integration test with claude-skill-tester (Claude-to-Claude conversation against real infrastructure). Use after writing or modifying a skill."
triggers: ["test skill", "eval skill", "test my skill", "run evals", "skill test", "does this skill work", "try the skill", "integration test", "skill feedback loop", "improve this skill", "fine tune skill"]
version: "1.0"
---

# Skill Tester

You have two tools for testing Claude Code skills. Both scripts are bundled with this skill at `$SKILL_DIR/`. Use them after writing or modifying a skill.

## When to use what

- **Wrote a new skill or changed one?** Run eval-skill first (fast, catches logic bugs), then claude-skill-tester if it needs real infrastructure testing.
- **User says "test this skill"?** Figure out if they want unit tests (eval) or a live run (integration). Ask if unclear.
- **Skill failed in production?** Use claude-skill-tester to reproduce, read the history, identify the issue, fix, retest.

## Tool 1: Unit Testing — eval-skill

Tests skill behavior without real infrastructure. Needs `evals/evals.json` in the skill directory.

```bash
bash "$SKILL_DIR/eval-skill.sh" /path/to/skills/my-skill/
```

If the skill doesn't have `evals/evals.json`, write one first. Each eval has a prompt and assertions:

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "Natural user prompt that should trigger the skill",
      "assertions": [
        "Does the right thing",
        "Does NOT do the wrong thing"
      ]
    }
  ]
}
```

Cover: happy path, scope handling, out-of-scope rejection, safety (refuses destructive ops), failure handling (missing creds).

After running, read the results. If assertions fail, read the skill, fix the behavior, and rerun.

## Tool 2: Integration Testing — claude-skill-tester

Spawns another Claude session that runs the skill against real infrastructure. You see every tool call, agent spawn, and error in real-time.

```bash
# Start a session pointing at the skill's repo
bash "$SKILL_DIR/claude-skill-tester.sh" start \
  --dir /path/to/skill/repo \
  --env "AWS_PROFILE=prod"

# Send a natural prompt — like a user would
bash "$SKILL_DIR/claude-skill-tester.sh" say "what's exposed to the internet in my AWS account?"

# Continue if the skill asks for input
bash "$SKILL_DIR/claude-skill-tester.sh" say "prod profile. full audit."

# Read results
bash "$SKILL_DIR/claude-skill-tester.sh" history
bash "$SKILL_DIR/claude-skill-tester.sh" cost

# Kill if stuck
bash "$SKILL_DIR/claude-skill-tester.sh" kill
```

You see the test session working in real-time:

```
[TOOL] Bash: bash preflight.sh
[TOOL] TeamCreate
[TOOL] Agent: investigator
[CLAUDE] Found 3 critical findings...
[DONE] success — 42 turns, $5.94
```

After the test, read the history, analyze what went wrong, fix the skill, and retest.

## The Feedback Loop

```
Write/modify skill
       │
       ▼
eval-skill (unit test) ── assertions pass? ── no → fix
       │ yes
       ▼
claude-skill-tester (integration test) ── works against real infra? ── no → fix
       │ yes
       ▼
done — commit the skill
```

## What each layer catches

| eval-skill (unit) | claude-skill-tester (integration) |
|---|---|
| Skill not triggering on prompts | DA being skipped |
| Wrong scope handling | Investigators bypassing DA |
| Not refusing destructive requests | Team broadcast errors |
| Not redirecting out-of-scope | Scores inflated by noise |
| Missing clarifying questions | Report validator not running |
