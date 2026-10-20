#!/usr/bin/env python3
"""PreToolUse: append the AGENTS.md orientation directive to a spawn prompt.

The failure this catches is MINE, not the agent's: subagents start with a fresh
context and never inherit the docs-first preference, so unless the spawn prompt
explicitly says "read the nearest AGENTS.md first", they beeline straight to
source and re-derive conventions from scratch (slower, and occasionally wrong
where the doc was right).

Fires only when ALL of:
  * the spawn prompt is substantial (>= MIN_CHARS) -- trivial/scoped tasks are
    left alone, since docs are pure overhead there and would only slow the agent
  * the prompt never mentions AGENTS.md
  * this project actually uses the AGENTS.md convention (else silent, so other
    repos get zero noise)

This REWRITES the prompt rather than warning about it. It was warn-only until
2026-08-28, and warn-only could not work by construction: PreToolUse warnings
surface AFTER the spawn, so the only repair left was a follow-up SendMessage --
the hook's own text said so. A reminder that arrives too late to act on cleanly
costs a turn of attention and still leaves the agent running unoriented.

The appended directive is CONDITIONAL ("if you read code in a subsystem..."), so
it stays harmless on the hook's unavoidable false positives -- it cannot tell a
repo-code task from a docs question or a web lookup, and guessing would be worse
than a spare sentence.

Silent by design: no systemMessage. The whole point is to stop spending the
user's attention on this. Never blocks a spawn, never fails a turn.
Docs orient, code decides.
"""

import glob
import json
import os
import sys

# Below this, a prompt is a trivial/scoped task where reading docs would cost
# more than it saves. The whole justification for docs-first is that it makes
# the agent FASTER; if it wouldn't, don't nudge.
MIN_CHARS = 600

# Appended verbatim to the spawn prompt. Kept short -- it rides along on every
# substantial spawn -- and conditional, so it costs a false positive nothing.
DIRECTIVE = (
    "\n\nBefore reading code in a subsystem, read its nearest AGENTS.md first to"
    " orient (skip this if the task doesn't involve reading this repo's code)."
    " Docs orient, code decides: verify anything correctness depends on against"
    " the source, and flag a stale doc rather than trusting it."
)


def uses_agents_md(root):
    """Cheap, depth-bounded check that this project uses the convention."""
    for pattern in ("AGENTS.md", "*/AGENTS.md", "*/*/AGENTS.md"):
        if glob.glob(os.path.join(root, pattern)):
            return True
    return False


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return  # a broken payload must never break a spawn

    tool_input = payload.get("tool_input") or {}
    prompt = tool_input.get("prompt") or ""

    if len(prompt) < MIN_CHARS:
        return
    if "agents.md" in prompt.lower():
        return

    root = (
        os.environ.get("CLAUDE_PROJECT_DIR")
        or payload.get("cwd")
        or os.getcwd()
    )
    if not uses_agents_md(root):
        return

    # updatedInput REPLACES the entire input object, so start from a copy of the
    # original and swap one key -- never rebuild it from known field names, or
    # every field not listed (model, name, isolation, run_in_background, ...)
    # is silently dropped from the spawn.
    updated_input = dict(tool_input)
    updated_input["prompt"] = prompt + DIRECTIVE

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated_input,
            },
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
