#!/usr/bin/env bash
# SessionStart hook: fetch origin and report branch sync state as additionalContext.
# Emits a hookSpecificOutput JSON blob so Claude confirms fetch completion + ahead/behind
# to the user at session start. Failures degrade gracefully (never blocks the session).
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5"

git -C "$DIR" fetch --quiet origin 2>/dev/null
counts=$(git -C "$DIR" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)

if [ -z "$counts" ]; then
  msg="git fetch ran but sync state could not be determined (no upstream tracking, or fetch failed). Mention this to the user."
else
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}
  branch=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
    msg="git fetch complete — '${branch}' is up to date with upstream (0 ahead / 0 behind). Confirm this to the user at session start."
  else
    msg="git fetch complete — '${branch}' is ${behind} behind / ${ahead} ahead of upstream. Surface this to the user at session start (offer to pull/rebase if behind)."
  fi
fi

# Emit JSON safely: escape the message with sed for embedding in the string field.
esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
