#!/usr/bin/env python3
"""UserPromptSubmit: when the owner's own typed message says to merge, open a
30-minute merge window for that session.

require-merge-approval.py denies every merge into main unless this window is
open. A PreToolUse "ask" is approved silently in bypass-permissions sessions
(seen 2026-10-04: `gh pr merge --auto` ran with no prompt), so the approval has
to come from the one input an agent cannot write: the owner's typed prompt.

A message counts when it contains a form of "merge" and no negation before it
("don't merge", "do not merge", "never merge", "not merge"). The window is
stored as a timestamp in ~/.claude/state/merge-approval/<session_id>.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time

DIR = os.path.expanduser("~/.claude/state/merge-approval")
MERGE = re.compile(r"\bmerg(e|es|ed|ing)\b", re.I)
NEGATED = re.compile(r"\b(don'?t|do not|never|not|no)\b[^.!?\n]{0,30}\bmerg", re.I)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt") or ""
sid = data.get("session_id") or ""
if sid and MERGE.search(prompt) and not NEGATED.search(prompt):
    os.makedirs(DIR, exist_ok=True)
    with open(os.path.join(DIR, re.sub(r"[^\w-]", "_", sid)), "w") as f:
        f.write(str(int(time.time())))
sys.exit(0)
