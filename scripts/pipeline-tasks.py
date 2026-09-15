#!/usr/bin/env python3
"""Generate pipeline/tasks.md — the file-based session task board.

Why this exists: the SessionStart bootstrap hooks ask the agent to restore every open
task into the session task list via the `TaskCreate` tool. That tool does not exist in
every Claude Code build (missing in the 2026-08 CLI on the Air), so the restore silently
degraded to "the agent read the docs and kept a list in its head". This script makes the
restore deterministic and file-backed instead: it scans BOTH task sources —

  * pipeline/todo.md          (live sprint board; every `- [ ]` / `- [~]` anywhere in it)
  * docs/improvement-plan.md  (durable backlog; `### [ ] NN. Title — **S**, PRIO` headings
                               and every open `- [ ]` / `- [~]` sub-item, including open
                               follow-ups that live under an already-[x] heading)

— and writes pipeline/tasks.md: one stable ID per open item, grouped by parent task,
ordered HIGH → MEDIUM → LOW, each pointing back at its source file:line. The SessionStart
hook runs this, so the board is fresh at the start of every session; `make tasks` runs it
on demand (e.g. after marking items [x] in the sources during a session).

Rules:
  * pipeline/tasks.md is GENERATED — never hand-edit it; change the source files.
  * Status lives in the sources ([ ] → [~] → [x]); this file only mirrors it.
  * Exit code is always 0 (a hook must not block the session); errors go to stderr.

Usage:
  scripts/pipeline-tasks.py            # regenerate, print a one-line summary
  scripts/pipeline-tasks.py --hook     # regenerate, print SessionStart JSON additionalContext
  scripts/pipeline-tasks.py --check    # exit 1 if pipeline/tasks.md is stale (for CI / wrapup)
"""
import json
import os
import re
import subprocess
import sys
from datetime import date

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TODO = os.path.join(ROOT, "pipeline", "todo.md")
PLAN = os.path.join(ROOT, "docs", "improvement-plan.md")
OUT = os.path.join(ROOT, "pipeline", "tasks.md")

OPEN_RE = re.compile(r"^(\s*)[-*] \[( |~)\] (.*)$")
HEAD_RE = re.compile(r"^(#{2,4}) (?:\[( |~|x)\] )?(.*)$")
# "### [ ] DR-2. Second backup destination + immutability — **M**, HIGH"
PLAN_HEAD_RE = re.compile(
    r"^(?P<num>[A-Z]*-?\d+[a-z]?)\.\s+(?P<title>.*?)(?:\s+—\s+\*\*(?P<size>[SML])\*\*,\s*(?P<prio>HIGH|MEDIUM|LOW))?\s*$"
)
PRIO_ORDER = {"HIGH": 0, "MEDIUM": 1, "LOW": 2, None: 3}


def read_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().splitlines()
    except FileNotFoundError:
        return None


def collect_items(lines):
    """Yield (lineno, status, text, heading_lineno) for every open checkbox item.

    Continuation lines (indented, not a new list item / heading / blank) are folded into
    the item text so multi-line bullets read as one task.
    """
    items = []
    heading = None  # (lineno, level, status, title)
    i = 0
    while i < len(lines):
        line = lines[i]
        hm = HEAD_RE.match(line)
        if hm:
            heading = (i + 1, len(hm.group(1)), hm.group(2), hm.group(3).strip())
            i += 1
            continue
        om = OPEN_RE.match(line)
        if om:
            indent, status, text = om.groups()
            start = i + 1
            j = i + 1
            parts = [text.strip()]
            while j < len(lines):
                nxt = lines[j]
                if not nxt.strip():
                    break
                if OPEN_RE.match(nxt) or re.match(r"^\s*[-*] \[x\] ", nxt) or HEAD_RE.match(nxt):
                    break
                if re.match(r"^\s*[-*] ", nxt) and len(nxt) - len(nxt.lstrip()) <= len(indent):
                    break
                if len(nxt) - len(nxt.lstrip()) <= len(indent) and not nxt.startswith(" "):
                    break
                parts.append(nxt.strip())
                j += 1
            items.append((start, status, " ".join(parts), heading))
            i = j
            continue
        i += 1
    return items


def squash(text, limit=220):
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def plan_groups(lines):
    """Group improvement-plan open items under their numbered task heading."""
    groups = {}  # key -> dict
    order = []
    for lineno, status, text, heading in collect_items(lines):
        if heading is None:
            key, meta = "_unfiled", {"num": "—", "title": "(no heading)", "size": None, "prio": None, "hstatus": None, "hline": 0}
        else:
            hline, _lvl, hstatus, htitle = heading
            pm = PLAN_HEAD_RE.match(htitle)
            if pm:
                meta = {"num": pm.group("num"), "title": pm.group("title").strip(), "size": pm.group("size"), "prio": pm.group("prio"), "hstatus": hstatus, "hline": hline}
            else:
                meta = {"num": "—", "title": htitle, "size": None, "prio": None, "hstatus": hstatus, "hline": hline}
            key = "%s@%d" % (meta["num"], hline)
        if key not in groups:
            groups[key] = {"meta": meta, "items": []}
            order.append(key)
        groups[key]["items"].append((lineno, status, text))
    # stable sort: priority, then order of appearance
    order.sort(key=lambda k: (PRIO_ORDER[groups[k]["meta"]["prio"]], groups[k]["meta"]["hline"]))
    return [groups[k] for k in order]


def git_head():
    try:
        return subprocess.check_output(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return "unknown"


def render(todo_lines, plan_lines):
    out = []
    todo_items = collect_items(todo_lines) if todo_lines is not None else []
    groups = plan_groups(plan_lines) if plan_lines is not None else []
    plan_items = sum(len(g["items"]) for g in groups)
    n_open = len(todo_items) + plan_items
    n_prog = sum(1 for it in todo_items if it[1] == "~") + sum(1 for g in groups for it in g["items"] if it[1] == "~")

    out.append("# Session task board — kubernetes (GENERATED)")
    out.append("")
    out.append("> **Do not edit by hand.** Generated by `scripts/pipeline-tasks.py` from `pipeline/todo.md` +")
    out.append("> `docs/improvement-plan.md`. Change status in THOSE files (`[ ]` → `[~]` → `[x]`), then")
    out.append("> `make tasks` to refresh. The SessionStart hook regenerates it automatically, so it is")
    out.append("> always current at session start. This file IS the session task list when the `TaskCreate`")
    out.append("> tool is unavailable (it is missing in some Claude Code builds); when `TaskCreate` exists,")
    out.append("> create one task per line below (subject = the item text, in_progress for `[~]`).")
    out.append("")
    # No git hash in the header (dropped 2026-09-15, #78.1): the file is Syncthing'd to machines
    # whose .git is not synced, so every SessionStart hook there stamped ITS OWN (stale) HEAD and
    # the churn dirtied the Air's tree with content-identical rewrites. Date + counts only.
    out.append("Generated %s · **%d open** (%d in progress) — %d from todo.md, %d from improvement-plan.md"
               % (date.today().isoformat(), n_open, n_prog, len(todo_items), plan_items))
    out.append("")
    out.append("ID scheme: `T<n>` = todo.md item (in file order); `<task>.<n>` = improvement-plan sub-item")
    out.append("under numbered task `<task>` (e.g. `DR-2.3`, `73.1`). `(Lnnn)` = source line at generation time.")
    out.append("")

    out.append("## docs/improvement-plan.md — open items by task (HIGH → MEDIUM → LOW)")
    out.append("")
    if not groups:
        out.append("_none_")
    for g in groups:
        m = g["meta"]
        hs = {" ": "open", "~": "in progress", "x": "task closed — open follow-ups", None: ""}[m["hstatus"]]
        size = ("%s, " % m["size"]) if m["size"] else ""
        prio = m["prio"] or "unprioritised"
        out.append("### %s. %s — %s%s — %s (L%d)" % (m["num"], m["title"], size, prio, hs, m["hline"]))
        for n, (lineno, status, text) in enumerate(g["items"], 1):
            out.append("- [%s] **%s.%d** (L%d) %s" % (status, m["num"], n, lineno, squash(text)))
        out.append("")

    out.append("## pipeline/todo.md — open items (file order; OPEN section first, then any left in history)")
    out.append("")
    if not todo_items:
        out.append("_none_")
    last_head = object()
    for n, (lineno, status, text, heading) in enumerate(todo_items, 1):
        htitle = heading[3] if heading else "(top of file)"
        if htitle != last_head:
            out.append("_under: %s_" % htitle)
            last_head = htitle
        out.append("- [%s] **T%d** (L%d) %s" % (status, n, lineno, squash(text)))
    out.append("")
    out.append("## Reminders")
    out.append("- Before the session ends (`/wrapup` step 3): every item you worked on must be `[x]`/`[~]` in the")
    out.append("  SOURCE file, then `make tasks` so this board matches. Items in todo.md that duplicate an")
    out.append("  improvement-plan sub-item should point at it (`→ #73`) and be closed in ONE place when done.")
    out.append("- Missing sources are reported on stderr and rendered as empty sections — never as 'no work'.")
    return "\n".join(out) + "\n"


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    todo = read_lines(TODO)
    plan = read_lines(PLAN)
    for name, val in (("pipeline/todo.md", todo), ("docs/improvement-plan.md", plan)):
        if val is None:
            print("pipeline-tasks: WARNING source missing: %s" % name, file=sys.stderr)
    content = render(todo, plan)
    summary_line = next(l for l in content.splitlines() if l.startswith("Generated "))

    if mode == "--check":
        try:
            with open(OUT, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            current = ""
        # ignore the date/git line when comparing
        strip = lambda s: "\n".join(l for l in s.splitlines() if not l.startswith("Generated "))
        if strip(current) != strip(content):
            print("pipeline-tasks: pipeline/tasks.md is STALE — run `make tasks`", file=sys.stderr)
            return 1
        print("pipeline-tasks: up to date")
        return 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(content)

    if mode == "--hook":
        ctx = (
            "SESSION TASK BOARD (auto, do not ask the user): pipeline/tasks.md was just regenerated "
            "from pipeline/todo.md + docs/improvement-plan.md — " + summary_line.replace("**", "") + ". "
            "Read pipeline/tasks.md. If a TaskCreate tool exists in this build, create one session task per "
            "open line (subject = item text; [~] → in_progress); if it does NOT exist (it is missing in some "
            "Claude Code builds — do not say the bootstrap failed), pipeline/tasks.md IS the session task "
            "list: work from it, mark items [x]/[~] in the SOURCE files as you go, and run `make tasks` to "
            "refresh it (mandatory in /wrapup step 3). Mention the open-count in the bootstrap greeting."
        )
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}))
    else:
        print("pipeline-tasks: wrote pipeline/tasks.md — " + re.sub(r"\*\*", "", summary_line))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # a hook must never block the session
        print("pipeline-tasks: ERROR %s" % exc, file=sys.stderr)
        sys.exit(0)
