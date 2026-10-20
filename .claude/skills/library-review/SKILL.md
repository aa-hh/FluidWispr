---
name: library-review
description: Run the design library reviewer on media-manager-2-design/library-changes.md, or pass it Alec's answers to rows waiting on him. Use when Alec types /library-review, optionally with answers like "approve 1, 2; reject 3, use 28px" or the word "backlog".
---

Start the `library-reviewer` agent with the Agent tool (`subagent_type: "library-reviewer"`, `run_in_background: true`) and tell Alec in one line that it's running and that he'll get a notification when it's done.

Pass the arguments through verbatim in the prompt:
- No arguments: "Run a library review of all pending rows in library-changes.md."
- Answers (anything with approve / reject / numbers): "Answer run. Alec's answers to the REVIEW numbers: <arguments verbatim>. Apply only changes he approved AND that the card already showed as before/after; anything else becomes a new Planned change card for him to approve first. Then review any other pending rows."
- `backlog`: "Backlog run: review backlog rows, at most 15 groups."

Before starting, run `~/.claude/scripts/library-review-status`. If there is nothing pending and no answers were given, say so and don't start the agent. Other reviews may be running; that's fine, the agent skips anything another live review has claimed (`~/.claude/library-review/claims/`). Mention in your one line if any claims are live.

Reviewers started this way can't send notifications themselves. When the agent finishes, send Alec one `PushNotification` with the first line of `~/.claude/library-review/last-run.txt`, then summarise the result in chat.
