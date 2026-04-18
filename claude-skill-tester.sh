#!/usr/bin/env bash
# claude-skill-tester — Test Claude Code skills by steering a Claude session programmatically
#
# Runs Claude in print mode with streaming JSON output, parses events in real-time,
# and maintains conversation history across turns. Designed to be called from another
# Claude session, a CI pipeline, or a shell script.
#
# Requirements: claude (Claude Code CLI), jq
#
# Usage:
#   claude-skill-tester start --dir /path/to/skill/repo --env KEY=VAL
#   claude-skill-tester say "your prompt"      # blocks, streams live output
#   claude-skill-tester history                 # full conversation log
#   claude-skill-tester stream                  # raw stream-json from last turn
#   claude-skill-tester kill                    # kill stuck session
#
# State is stored in ~/.claude-skill-tester/active/

set -euo pipefail

TESTER_HOME="${CLAUDE_SKILL_TESTER_HOME:-$HOME/.claude-skill-tester}"
SESSION_DIR="$TESTER_HOME/active"
mkdir -p "$SESSION_DIR"

HISTORY_FILE="$SESSION_DIR/history.md"
WORKDIR_FILE="$SESSION_DIR/workdir"
ENV_FILE="$SESSION_DIR/env"
TURN_FILE="$SESSION_DIR/turn"
TOOLS_FILE="$SESSION_DIR/tools"
TURNS_FILE="$SESSION_DIR/max_turns"
PID_FILE="$SESSION_DIR/pid"
STREAM_FILE="$SESSION_DIR/stream.jsonl"
COST_FILE="$SESSION_DIR/total_cost"

cmd="${1:-help}"
shift || true

# Parse a stream-json event into human-readable output
parse_event() {
  local line="$1"
  local type
  type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || return

  case "$type" in
    assistant)
      local content_type
      content_type=$(echo "$line" | jq -r '.message.content[-1].type // empty' 2>/dev/null) || return
      case "$content_type" in
        text)
          local text
          text=$(echo "$line" | jq -r '.message.content[-1].text // empty' 2>/dev/null)
          if [ -n "$text" ]; then
            echo "[CLAUDE] $text"
          fi
          ;;
        tool_use)
          local tool_name tool_desc tool_cmd tool_skill tool_file
          tool_name=$(echo "$line" | jq -r '.message.content[-1].name // empty' 2>/dev/null)
          tool_desc=$(echo "$line" | jq -r '.message.content[-1].input.description // empty' 2>/dev/null)
          tool_cmd=$(echo "$line" | jq -r '.message.content[-1].input.command // empty' 2>/dev/null)
          tool_skill=$(echo "$line" | jq -r '.message.content[-1].input.skill // empty' 2>/dev/null)
          tool_file=$(echo "$line" | jq -r '.message.content[-1].input.file_path // empty' 2>/dev/null)
          if [ -n "$tool_skill" ]; then
            echo "[TOOL] $tool_name → skill: $tool_skill"
          elif [ -n "$tool_cmd" ]; then
            local short_cmd
            short_cmd=$(echo "$tool_cmd" | head -1 | cut -c1-120)
            echo "[TOOL] $tool_name: $short_cmd"
          elif [ -n "$tool_file" ]; then
            echo "[TOOL] $tool_name: $tool_file"
          elif [ -n "$tool_desc" ]; then
            echo "[TOOL] $tool_name: $tool_desc"
          else
            echo "[TOOL] $tool_name"
          fi
          ;;
      esac
      ;;
    user)
      local is_error
      is_error=$(echo "$line" | jq -r '.message.content[0].is_error // false' 2>/dev/null)
      if [ "$is_error" = "true" ]; then
        local err
        err=$(echo "$line" | jq -r '.message.content[0].content // empty' 2>/dev/null | head -1 | cut -c1-150)
        echo "[ERROR] $err"
      fi
      ;;
    result)
      local subtype cost turns
      subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
      cost=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)
      turns=$(echo "$line" | jq -r '.num_turns // 0' 2>/dev/null)
      echo "[DONE] $subtype — $turns turns, \$$cost"
      echo "$cost" > "$COST_FILE"
      ;;
  esac
}

case "$cmd" in
  start)
    workdir="$(pwd)"
    env_vars=()
    allowed_tools="Bash(*) Read(*) Write(*) Glob(*) Grep(*) Skill(*) Agent(*) TeamCreate(*) TeamDelete(*) SendMessage(*)"
    max_turns=80

    while [ $# -gt 0 ]; do
      case "$1" in
        --dir)      workdir="$2"; shift 2 ;;
        --env)      env_vars+=("$2"); shift 2 ;;
        --tools)    allowed_tools="$2"; shift 2 ;;
        --turns)    max_turns="$2"; shift 2 ;;
        *)          shift ;;
      esac
    done

    rm -f "$PID_FILE" "$HISTORY_FILE" "$TURN_FILE" "$STREAM_FILE" "$COST_FILE"
    echo "$workdir" > "$WORKDIR_FILE"
    if [ ${#env_vars[@]} -gt 0 ]; then
      printf '%s\n' "${env_vars[@]}" > "$ENV_FILE"
    else
      echo "" > "$ENV_FILE"
    fi
    echo "0" > "$TURN_FILE"
    echo "" > "$HISTORY_FILE"
    echo "$allowed_tools" > "$TOOLS_FILE"
    echo "$max_turns" > "$TURNS_FILE"

    echo "Session ready."
    echo "  workdir: $workdir"
    echo "  max_turns: $max_turns"
    echo ""
    echo "Next: claude-skill-tester say \"your prompt\""
    ;;

  say)
    prompt="$*"
    if [ -z "$prompt" ]; then
      echo "Usage: claude-skill-tester say \"your prompt\""
      exit 1
    fi

    # Kill any leftover process
    if [ -f "$PID_FILE" ]; then
      old_pid=$(cat "$PID_FILE")
      kill "$old_pid" 2>/dev/null || true
      rm -f "$PID_FILE"
    fi

    workdir=$(cat "$WORKDIR_FILE" 2>/dev/null || echo "$(pwd)")
    max_turns=$(cat "$TURNS_FILE" 2>/dev/null || echo "80")
    turn=$(cat "$TURN_FILE" 2>/dev/null || echo "0")
    turn=$((turn + 1))
    echo "$turn" > "$TURN_FILE"

    # Build env exports
    env_exports=""
    if [ -f "$ENV_FILE" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && env_exports="export $line && $env_exports"
      done < "$ENV_FILE"
    fi

    # Build --allowedTools args
    tools_args=""
    if [ -f "$TOOLS_FILE" ]; then
      for tool in $(cat "$TOOLS_FILE"); do
        tools_args="$tools_args --allowedTools '$tool'"
      done
    fi

    # --continue for turn 2+
    continue_flag=""
    if [ "$turn" -gt 1 ]; then
      continue_flag="--continue"
    fi

    # Log user prompt
    echo -e "\n---\n## Turn $turn (user)\n$prompt" >> "$HISTORY_FILE"

    # Stream claude output, parse events in real-time
    echo "" > "$STREAM_FILE"

    (
      eval "cd '$workdir' && $env_exports claude -p \"\$prompt\" $tools_args --max-turns $max_turns $continue_flag --output-format stream-json --verbose"
    ) 2>&1 | tee -a "$STREAM_FILE" | while IFS= read -r line; do
      parse_event "$line"
    done

    # Extract final text response for history
    final_text=$(grep '"type":"assistant"' "$STREAM_FILE" 2>/dev/null | grep '"text"' | tail -1 | jq -r '.message.content[-1].text // empty' 2>/dev/null || echo "(no text)")
    echo -e "\n## Turn $turn (claude)\n$final_text" >> "$HISTORY_FILE"
    ;;

  history)
    if [ ! -f "$HISTORY_FILE" ]; then
      echo "(no history — run 'start' first)"
      exit 0
    fi
    cat "$HISTORY_FILE"
    ;;

  stream)
    if [ ! -f "$STREAM_FILE" ]; then
      echo "(no stream data — run 'say' first)"
      exit 0
    fi
    cat "$STREAM_FILE"
    ;;

  cost)
    if [ -f "$COST_FILE" ]; then
      echo "Total cost: \$$(cat "$COST_FILE")"
    else
      echo "No cost data yet."
    fi
    ;;

  kill)
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      kill "$pid" 2>/dev/null && echo "Killed $pid" || echo "Already exited"
      rm -f "$PID_FILE"
    fi
    pkill -f "claude -p" 2>/dev/null || true
    echo "Cleaned up."
    ;;

  help|*)
    cat << 'HELP'
claude-skill-tester — Test Claude Code skills by steering sessions programmatically

Commands:
  start   Initialize a test session
          --dir <path>     Working directory (default: cwd)
          --env KEY=VAL    Environment variable (repeatable)
          --tools "..."    Allowed tools (default: Bash,Read,Write,Glob,Grep,Skill,Agent,Teams)
          --turns N        Max turns per say (default: 80)

  say     Send a prompt and stream the response
          Blocks until Claude responds. Streams tool calls and text in real-time.
          Uses --continue automatically for multi-turn conversations.

  history Show the full conversation (user prompts + claude responses)
  stream  Show raw stream-json from the last turn
  cost    Show cumulative API cost
  kill    Kill a stuck Claude process

Examples:
  # Test an AWS skill
  claude-skill-tester start --dir ~/devops-skills --env "AWS_PROFILE=prod"
  claude-skill-tester say "what's exposed to the internet in my AWS account?"
  claude-skill-tester say "prod profile. full audit."

  # Test a K8s skill
  claude-skill-tester start --dir ~/devops-skills
  claude-skill-tester say "my pod is crashing with OOMKilled"

  # Review what happened
  claude-skill-tester history
  claude-skill-tester cost

State: ~/.claude-skill-tester/active/
Requires: claude (Claude Code CLI), jq
HELP
    ;;
esac
