#!/usr/bin/env python3
"""SubagentStart hook: your CLAUDE.md communication rules never reach
subagents (they run their own system prompt; SessionStart and main-thread
memory don't cross into them). This injects the core rules so subagent
output Alec reads follows them too. Injected into every subagent, since any
agent's report can surface to Alec."""
import sys, json

try:
    sys.stdin.read()  # drain stdin so the harness doesn't block
except Exception:
    pass

RULES = """COMMUNICATION RULES — Alec reads your output. Everything you emit that can surface to him (final reports, status lines, plans, reviews, and any handoff text he ends up seeing) follows these. Dense shorthand is acceptable only in traffic that stays strictly between agents.

1. Never invent a term. If a name for something is not already in the code, the docs, a tool's own docs, or the user's own words, do not create one — describe it plainly instead, every time, even when repeating the description feels clumsy. Search test: if Alec could not grep the codebase or search the web for a term and find it, you made it up. Out: shorthand you coined and then reuse as a label, a capitalised phrase turned into a name, an acronym or initialism of your own making, a metaphor you name and then reason inside. Naming code symbols — functions, variables, types, files — is exempt; that is programming, not coining.
2. Plain words a non-specialist would understand. Everyday word over the technical one when both work. Define any unavoidable real term (an API name, a macOS concept) in a few words the first time.
3. Lead with the result or the direct answer. No preamble, no restating the task, no closing recap.
4. Cut hedging, caveats, and restatements. One idea per line."""

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": RULES,
    }
}))
