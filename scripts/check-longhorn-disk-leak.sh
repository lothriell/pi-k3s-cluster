#!/usr/bin/env bash
# check-longhorn-disk-leak.sh
#
# Detects the "phantom disk" failure mode where a wedged longhorn-engine
# replica process holds large *deleted* files open: the files are unlinked
# from the filesystem (so `du` can't see them) but a running process still
# holds the fd, so `df` keeps counting the space. Symptom: node disk ~90%
# full while `du -x /` only accounts for ~60%.
#
# Root case 2026-06-05: prometheus replica on k3s-x86-1 held ~45 GiB of
# deleted snapshot/head files since the 2026-06-04 attach-storm incident.
# Full writeup + remediation: ~/.claude memory
#   feedback_longhorn_phantom_disk_orphan_replica
#
# Usage:   sudo ./check-longhorn-disk-leak.sh [threshold_gib]
#   threshold_gib  report a process only if it holds > this many GiB of
#                  deleted longhorn files (default 2).
#
# Exit 0 = clean, 1 = leak found (so it can gate `make status` / alerting).
# Needs root to readlink other processes' /proc/<pid>/fd entries.
set -uo pipefail

THRESHOLD_GIB="${1:-2}"
host="$(hostname -s 2>/dev/null || hostname)"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

# Disk headline for the filesystem backing Longhorn (skip if no Longhorn here).
if [[ -d /var/lib/longhorn ]]; then
  df -Ph /var/lib/longhorn 2>/dev/null | awk -v h="$host" \
    'NR==2{printf "%-14s df: %s used / %s (%s full)\n", h, $3, $2, $5}'
else
  printf '%-14s no /var/lib/longhorn (not a storage node)\n' "$host"
  exit 0
fi

# Scan every process fd for deleted files whose path is under longhorn.
# IMPORTANT: Longhorn volume files are SPARSE — the logical size (stat %s) is the
# volume's nominal capacity and wildly overcounts. Measure ACTUALLY-ALLOCATED
# blocks (%b * %B) and dedup by inode (a process opens the same file via several
# fds; that's one chunk of disk, not N). Emits: pid inode alloc_bytes
for fd in /proc/[0-9]*/fd/*; do
  t="$(readlink "$fd" 2>/dev/null)" || continue
  [[ "$t" == *longhorn*"(deleted)" ]] || continue
  read -r blocks bsize inode < <(stat -L -c '%b %B %i' "$fd" 2>/dev/null) || continue
  pid="${fd#/proc/}"; pid="${pid%%/*}"
  echo "$pid $inode $(( blocks * bsize ))" >> "$tmp"
done

rc=0
if [[ -s "$tmp" ]]; then
  awk -v th="$THRESHOLD_GIB" -v h="$host" '
    # dedup by inode globally (shared blocks counted once); attribute to first pid seen
    !seen[$2]++ { bytes[$1] += $3 }
    END{
      for (p in bytes) {
        g = bytes[p] / 1073741824
        if (g > th) {
          printf "  WARN %s pid=%s holds %.1f GiB of DELETED longhorn data on disk (wedged replica?)\n", h, p, g
          bad = 1
        }
      }
      exit (bad ? 1 : 0)
    }' "$tmp" || rc=1
fi

[[ $rc -eq 0 ]] && echo "  ok: no wedged replicas holding >${THRESHOLD_GIB} GiB deleted files"
exit $rc
