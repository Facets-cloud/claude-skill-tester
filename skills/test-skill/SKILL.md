---
title: "Skill Tester"
description: "Test and improve Claude Code skills. Unit test with eval-skill (LLM-judged assertions). Integration test with claude-skill-tester (Claude-to-Claude conversation against real infrastructure). Use after writing or modifying a skill."
triggers: ["test skill", "eval skill", "test my skill", "run evals", "skill test", "does this skill work", "try the skill", "integration test", "skill feedback loop", "improve this skill", "fine tune skill"]
version: "1.0"
---

# Skill Tester

You have two testing tools bundled at `$SKILL_DIR/`. Your job is to test a skill, figure out what's wrong, fix it, and confirm the fix works.

## The two tools

**`eval-skill.sh`** — unit tests. Sends test prompts to a Claude with the skill loaded, then a judge checks if assertions pass. Fast, no real infrastructure. Needs `evals/evals.json` in the skill directory — if it doesn't exist, write one before testing.

```bash
bash "$SKILL_DIR/eval-skill.sh" /path/to/skill/
```

**`claude-skill-tester.sh`** — integration tests. Spawns another Claude session with the skill loaded and real credentials. You send it prompts like a user would and see every tool call, agent spawn, and error streamed back. Use this when unit tests pass but you need to see how the skill actually behaves.

```bash
bash "$SKILL_DIR/claude-skill-tester.sh" start --dir /path/to/repo --env "KEY=VAL"
bash "$SKILL_DIR/claude-skill-tester.sh" say "natural user prompt"
bash "$SKILL_DIR/claude-skill-tester.sh" say "follow-up if skill asks"
bash "$SKILL_DIR/claude-skill-tester.sh" history
bash "$SKILL_DIR/claude-skill-tester.sh" cost
bash "$SKILL_DIR/claude-skill-tester.sh" kill
```

## How to think about testing

Unit tests and integration tests catch different things. Unit tests catch logic — does the skill trigger, does it refuse destructive requests, does it redirect out-of-scope? Integration tests catch architecture — does the DA actually review findings, do agents communicate correctly, does the validator run?

If you're not sure which to run, start with unit tests. They're faster and cheaper. If they pass and the user still reports problems, move to integration.

When a test fails, read the failure carefully. The problem is usually in the skill, not the assertion. Read the skill definition, understand why it produced the wrong behavior, fix it, and rerun. Don't weaken assertions to make them pass — fix the skill.

## Writing evals

If the skill doesn't have `evals/evals.json`, write one. Think about what matters for this specific skill — not a generic checklist, but what would actually go wrong if the skill misbehaves.

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "Natural prompt a real user would say",
      "assertions": [
        "What the skill should do",
        "What the skill should NOT do"
      ]
    }
  ]
}
```

Good assertions test behavior and judgment, not exact wording. "Asks for clarification before acting" not "Says the words 'could you clarify'". Test what matters — if the skill audits security, test that it catches real risks AND that it doesn't cry wolf on intentional exposure.

## Analyzing integration test results

After an integration test, read the history and the stream. The stream shows raw events — tool calls, errors, agent spawns. Look for patterns:

- Agents writing findings to temp files instead of communicating through the team
- Steps being skipped (validator not running, DA not reviewing)
- Errors from tools the skill assumed existed
- The skill asking the wrong questions or skipping user confirmation

The history shows the conversation. Read it like you're the user — does the skill's behavior make sense? Would you trust its output? Would you know what to do with the report?

Fix what you find, retest until clean.
