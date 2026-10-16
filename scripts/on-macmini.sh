#!/usr/bin/env bash
# Run a long job on the macmini inside tmux (#82.1).
#
# The Air sleeps on lid close (caffeinate -i doesn't stop clamshell sleep) and
# took the 2026-10-15/16 fleet upgrade down with it. The macmini never sleeps,
# has LAN reach to every VLAN, holds vault_pass, and since playbook 28 its key
# is trusted fleet-wide.
#
#   scripts/on-macmini.sh [-n NAME] [-f] -- COMMAND...
#     -n NAME  tmux session / log name (default job-YYYYmmdd-HHMM)
#     -f       launch even if the macmini's repo copy differs from this one
#
# The repo reaches the macmini via Syncthing (no .git there), so before
# launching, every tracked or new (non-ignored) file plus the gitignored inventory vars is compared
# by checksum; a mismatch aborts (Syncthing lag would run stale playbooks).
# Output goes to ~/logs/NAME.log on the macmini (last line "[exit RC] date");
# the pane drops to a shell afterwards so the output stays on screen.
set -euo pipefail

HOST="${MACMINI_SSH:-$USER@macmini-ts}"   # same personal user on both Macs
REPO='claude/kubernetes'
name="job-$(date +%Y%m%d-%H%M)"
force=0

while getopts "n:f" o; do
  case "$o" in n) name=$OPTARG ;; f) force=1 ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift
(( $# )) || { echo "usage: $0 [-n NAME] [-f] -- COMMAND..." >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"

# rsync -n -c: list (not copy) files whose content differs on the macmini.
drift=$({ git ls-files -co --exclude-standard; ls ansible/inventory/group_vars/all/{main,vault}.yml; } \
  | rsync -n -ci --files-from=- . "$HOST:$REPO/" | awk '{print $2}')
if [[ -n "$drift" ]]; then
  echo "macmini repo copy differs (Syncthing not caught up?):" >&2
  sed 's/^/  /' <<<"$drift" >&2
  (( force )) || { echo "wait for sync, or -f to launch anyway" >&2; exit 1; }
fi

job="set -o pipefail; cd ~/$REPO && $(printf '%q ' "$@") 2>&1 | tee ~/logs/$name.log; rc=\$?; echo \"[exit \$rc] \$(date)\" | tee -a ~/logs/$name.log; exec bash -l"

ssh "$HOST" "export PATH=/opt/homebrew/bin:\$PATH; mkdir -p ~/logs
  tmux has-session -t $(printf %q "$name") 2>/dev/null && { echo 'session $name exists' >&2; exit 1; }
  tmux new-session -d -s $(printf %q "$name") -x 200 -y 50 bash -lc $(printf %q "export PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH; $job")"

cat <<EOF
started '$name' on $HOST
  attach:  ssh -t $HOST /opt/homebrew/bin/tmux attach -t $name
  log:     ssh $HOST tail -f logs/$name.log
EOF
