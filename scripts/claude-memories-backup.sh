#!/usr/bin/env bash
# =============================================================================
# claude-memories-backup.sh — off-site, immutable copy of ~/.claude (DR-2 scope add)
# =============================================================================
# Why: the 2026-05-08 Syncthing cascade-delete silently destroyed 34 memory files
# and nothing noticed for 3 months — Syncthing (even with staggered versioning)
# is replication, not backup. This pushes the Claude Code state that is NOT in
# any git repo to a Backblaze B2 bucket with Object Lock, daily, via launchd.
#
# What is backed up (rclone sync, deletions = hides on B2, lock keeps versions):
#   ~/.claude/projects/        memories + session transcripts (agent-*.jsonl excluded:
#                              subagent logs, huge + regenerable)
#   ~/.claude/CLAUDE.md, settings*.json, keybindings.json   (symlinks resolved)
# NOT backed up: ~/.claude/plugins (reinstallable), caches, *.lock.
#
# Setup (once per Mac; both Air and macmini run their own copy of this):
#   1. brew install rclone
#   2. B2 bucket `homielab-claude-memories` — Object Lock ON at creation,
#      default retention governance 30d, lifecycle keep-prior-versions 30d;
#      restricted application key (listFiles readFiles writeFiles deleteFiles
#      listBuckets; NO bypassGovernance).
#   3. rclone config: remote name `b2-claude`, type b2, account = keyID,
#      key = applicationKey  (→ ~/.config/rclone/rclone.conf, mode 600)
#   4. Install the launchd job (02:30 daily + RunAtLoad):
#        make claude-backup-install      (from the kubernetes repo on this Mac)
#      or by hand: copy scripts/launchd/com.homielab.claude-backup.plist to
#        ~/Library/LaunchAgents/ and `launchctl load -w` it.
#   5. Verify: `claude-memories-backup.sh` (manual run) then
#        rclone lsd b2-claude:homielab-claude-memories
#
# Restore: rclone copy b2-claude:homielab-claude-memories/projects ~/.claude/projects
#          (add --b2-version-at "2026-05-07T23:00:00Z" for a point-in-time view)
#
# Exit codes: 0 ok, 1 rclone failure (launchd logs to ~/Library/Logs/claude-backup.log)
# =============================================================================
set -uo pipefail

REMOTE="${CLAUDE_BACKUP_REMOTE:-b2-claude:homielab-claude-memories}"
SRC_DIR="${HOME}/.claude"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LOG="${HOME}/Library/Logs/claude-backup.log"
RCLONE="$(command -v rclone || echo /opt/homebrew/bin/rclone)"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

[ -x "$RCLONE" ] || { log "ERROR rclone not found (brew install rclone)"; exit 1; }
[ -d "$SRC_DIR/projects" ] || { log "ERROR $SRC_DIR/projects missing — refusing to sync an empty source"; exit 1; }

# Guard against syncing a half-empty tree (Syncthing marker-missing recovery, fresh
# machine): require a sane minimum of memory files before touching the remote.
n_md=$(find "$SRC_DIR/projects" -path '*/memory/*.md' 2>/dev/null | wc -l | tr -d ' ')
MIN_MD="${CLAUDE_BACKUP_MIN_MD:-20}"
if [ "$n_md" -lt "$MIN_MD" ]; then
  log "ERROR only $n_md memory .md files under projects/ (< $MIN_MD) — source looks incomplete, NOT syncing"
  exit 1
fi

rc=0
log "start host=$HOST → $REMOTE (memory files: $n_md)"

# 1) projects/ — memories + transcripts, per-host prefix so Air and macmini don't
#    fight over deletions (they are Syncthing-identical anyway; per-host keeps the
#    history independent if one of them goes bad).
"$RCLONE" sync "$SRC_DIR/projects" "$REMOTE/$HOST/projects" \
  --exclude '**/agent-*.jsonl' --exclude '**/.DS_Store' --exclude '**/*.lock' \
  --fast-list --transfers 8 --checkers 16 \
  --b2-hard-delete=false \
  --stats-one-line --stats 0 --log-level NOTICE --log-file "$LOG" || rc=1

# 2) top-level config files (follow symlinks → dotfiles content is captured)
tmp=$(mktemp -d)
for f in CLAUDE.md settings.json settings.local.json keybindings.json; do
  [ -e "$SRC_DIR/$f" ] && cp -L "$SRC_DIR/$f" "$tmp/$f"
done
"$RCLONE" sync "$tmp" "$REMOTE/$HOST/config" --b2-hard-delete=false \
  --stats-one-line --stats 0 --log-level NOTICE --log-file "$LOG" || rc=1
rm -rf "$tmp"

if [ $rc -eq 0 ]; then
  log "ok host=$HOST"
else
  log "FAILED host=$HOST (rc=$rc) — see $LOG"
fi
exit $rc
