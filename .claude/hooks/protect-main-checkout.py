#!/usr/bin/env python3
"""PreToolUse gate: keep file writes out of FluidWispr's main checkout.

WHY THIS EXISTS
---------------
Local work happens in per-session worktrees under
`.claude/worktrees/<slug>` (see CLAUDE.md). The main checkout
(/Users/alechenderson/FluidWispr) is a shared live workspace and should stay
clean until a branch is merged. But sessions occasionally target the main
checkout path directly (absolute path, or an edit resolved against the wrong
root), and the change lands there silently: the file is never committed, so no
commit-time hook catches it. A PreToolUse hook fires on the write itself, and
still fires for autonomous agents that skip the normal per-tool prompt.

WHAT IT DOES
------------
Fires on Edit / Write / MultiEdit / NotebookEdit. The main checkout is found
from the tool's cwd (`git rev-parse --git-common-dir`; its parent when it ends
in `/.git`), so the same file works in any clone. If the target path is inside
the main checkout but not inside `.claude/worktrees/` or `.worktrees/`, it
returns permissionDecision "ask" so the write surfaces for a human before it
lands. It never hard-blocks.

Cloud sessions (CLAUDE_CODE_REMOTE_SESSION_ID set) work in their own clone, not
a worktree, so the hook does nothing there.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

if os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID"):
    sys.exit(0)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # unparseable input -> never interfere

ti = data.get("tool_input") or {}
target = ti.get("file_path") or ti.get("notebook_path") or ""
if not target:
    sys.exit(0)

cwd = data.get("cwd") or os.getcwd()
try:
    common = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-common-dir"],
                            capture_output=True, text=True, timeout=5).stdout.strip()
except Exception:
    sys.exit(0)
common = os.path.abspath(os.path.join(cwd, common)) if common else ""
if not common.endswith(os.sep + ".git"):
    sys.exit(0)  # not a git checkout, or a bare/unusual layout
MAIN_ROOT = os.path.dirname(common)
WORKTREE_DIRS = (
    os.path.join(MAIN_ROOT, ".claude", "worktrees"),
    os.path.join(MAIN_ROOT, ".worktrees"),
)

# Resolve relative to the tool's cwd so relative paths are judged correctly.
path = os.path.abspath(target if os.path.isabs(target) else os.path.join(cwd, target))

root = MAIN_ROOT + os.sep
worktrees = tuple(d + os.sep for d in WORKTREE_DIRS)

in_main = path.startswith(root) and not path.startswith(worktrees)

# Ignored scratch and planning notes are meant to be written in the main
# checkout: an ignored file in a worktree dies with it.
INTERNAL_DIRS = (".scratch/", "docs/plans/", "docs/notes/")
if in_main:
    rel = path[len(root):]
    name = os.path.basename(rel).lower()
    if rel.startswith(INTERNAL_DIRS) or (name.endswith(".md") and ("handoff" in name or "handover" in name)):
        in_main = False
if in_main:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": (
                f"This writes into the main checkout ({path}), not a worktree. "
                "Work belongs in .claude/worktrees/<slug>/ until it's committed "
                "and ready to merge. Confirm only if you really mean to touch main."
            ),
        }
    }))

sys.exit(0)
