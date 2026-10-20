---
name: scope-and-run3
description: Trial version of /scope-and-run with a team-scoping step (a small team of scopers only when the first scoper reports questions across several areas), a pre-scoping interview for open decisions, a quick medium-effort scoper for small tasks, test-first work orders, and ticket input. Use ONLY when the user invokes /scope-and-run3 by name; plain "scope and run" requests go to /scope-and-run.
---

Run the full scope→execute pipeline for the request in $ARGUMENTS.

**You are the orchestrator, not an implementer.** From here until the final report, you do not use Edit, Write, or any file-modifying Bash command. Every code change is made by a `work-order-executor` agent. If you catch yourself about to edit a file, that work belongs in a track — launch an executor instead. Four exceptions only: the escape hatch in Step 0 (decided there and never after), the `CONTEXT.md` and `docs/adr/` entries the Step 0 interview writes, saving the work order, and appending to the team decision log in Step 1.2.

**Nobody commits.** Executors and reviewers never `git commit` or `git push`; all work stays uncommitted in the working tree until the user has seen the final report and decides. Include this in every executor prompt.

## Launching agents — background by default

Every Agent call in this pipeline uses `run_in_background: true` and a `name` (e.g. `scoper`, `exec-<track>`, `reviewer`). After launching, tell the user in one line what is running, then end your turn. Do not poll or sleep. The app wakes you when each agent finishes, and the user can talk to you meanwhile. This is safe only because you are the main session. A subagent is never woken by its own children (see the stall rule below).

Two causes produced the stalls that used to force foreground runs: a subagent that starts background work and ends its turn is never woken, and builds and tests queue for up to 600 s behind other sessions for a shared slot. The rules that block both live in the "Background work and capacity" section of every agent definition this pipeline uses (`~/.claude/agents/`), so they load whatever the prompt says. Only use those agent types here; a `general-purpose` agent does not carry the rules.

**Size the fan-out to capacity.** Before Step 2, when the repo has `scripts/capacity.sh`, run `bash scripts/capacity.sh status`. Launch at most as many parallel tracks as there are free permits on both machines combined (minimum 1). Hold the remaining independent tracks and launch each one as a running track returns. Tell the user in one line if you are holding tracks back and why.

**Start the stall timer after every launch.** Each background Agent launch returns an `output_file` path. Right after launching, start `python3 ~/.claude/skills/scope-and-run/watch-helpers.py <output_file> ...` (every running helper's path) with Bash `run_in_background: true`. It exits, and so wakes you, when all listed helpers have finished (`ALL FINISHED`, nothing to do) or one has written nothing for 20 minutes (`STALE`). On `STALE`, follow the next paragraph; to restart a stuck helper, stop it with `TaskStop` first. Restart the timer whenever you launch more helpers. Each agent file also sets `maxTurns`, so a helper stuck in a loop stops on its own and reports partial work.

**When an agent is silent.** If the user asks about an agent, or one has run far past what its track should take, check its worktree yourself (`git -C <worktree> status --short`, `git -C <worktree> diff --stat`) and `capacity.sh status` before sending it a message. Queued for a permit → keep waiting. No file changes and no permit held → ask it for status by SendMessage once, then relaunch that one track fresh.

**Opus mode:** if the user says "opus mode" / "no fable", or any Fable agent call fails for quota/availability reasons, run the whole pipeline on Opus: use `opus-scoper2` instead of `fable-scoper2` in Step 1, and the Opus reviewer variant in Step 4. Tell the user in one line which mode is running. Everything else is identical.

**Input.** `$ARGUMENTS` is either a plain request or a path to a ticket or spec under `.scratch/<slug>/` (written by `/to-spec` or `/to-tickets`). For a ticket, read it, the feature's `spec.md`, and every ticket on its `Blocked by` line. If a blocker is not done yet, name it and stop. A ticket's decisions count as settled, and its acceptance criteria are part of the request.

**Saved work order.** The work order is saved to `.scratch/<slug>/work-order.md`, or beside a ticket as `issues/NN-<slug>.work-order.md`. If one already exists for this request, ask the user whether to resume from it (skip to Step 2) or scope again.

## Step 0 — Size and open decisions (before any agent launches)

Decide these three from the request and this conversation, then tell the user the outcome in one line.

1. **Too small for the pipeline?** A single obvious edit with no design decisions: say "Too small for the pipeline" and do it directly. Once a scoper has launched, this is closed — a task that looked big enough to scope is big enough to execute through a track.
2. **Open decisions?** If the request leaves a product or design choice open (what it should do, how it looks, what a new thing is called, which of several behaviours) and no ticket or spec already settled it, interview the user before scoping: load the `grilling` and `domain-modeling` skills and follow them until every open decision is answered and the user confirms. Include the test seam among the questions when the change has behaviour a test can see: which existing test file or suite should prove it. The interview may write `CONTEXT.md` and `docs/adr/` and nothing else, and never from the `main` checkout. Pass the answers to the scoper as a **Settled decisions** list. If the request only says how to do something already decided, skip the interview.
3. **Quick or full scoping?** Quick when all hold: expected to touch 3 files or fewer, no decision still open after the interview, nothing in the risky areas listed in Step 4. Quick uses `fable-scoper-quick2`, everything else `fable-scoper2`. Opus mode always uses `opus-scoper2`.

## Step 1 — Scope

Launch the scoper chosen in Step 0 in the background (named `scoper`) with the user's request, the Settled decisions list if there is one, and any relevant context from this conversation (why they want it, constraints they mentioned). Add this instruction to its prompt verbatim:

> End the work order with a `## Cross-area questions` section. List every fact your steps depend on that lives in a part of the codebase you did not research closely enough to cite with file:line, one per line, each tagged with the folder or module it lives in: `- [<area>] <question> (affects steps N, M)`. Write `None` if every dependency is cited. Do not pad this list; a question you could settle with one more read, settle instead.

- If it returns clarifying questions: relay them to the user with AskUserQuestion using the scoper's recommended defaults, then re-run the scoper with the answers. Do not guess on its behalf.
- If `fable-scoper-quick2` returns "Bigger than it looked": re-run once with `fable-scoper2`, passing what it found.
- If it returns a work order: save it to the path above, then proceed. On any later revision, overwrite it and put one line at the top saying why it was revised. Show the user only a 4-line digest (goal, step count, test seam, verification command) — not the full document.

### Step 1.2 — One scoper or a team (trial, 2026-09-26)

Decide from the work order's `## Cross-area questions` section only, never from how big the request sounds. History: across ~157 scoping jobs (2026-08-08 to 2026-09-20), one scoper needing another's finding happened once, so a team should be rare.

- **`None`, or the section is missing** → proceed.
- **1 or 2 questions, or all questions in one area** → settle them without a team. Read the code yourself if each is one lookup; otherwise launch one `fable-scoper-team` agent (named `scope-<area>`) with the questions. Then SendMessage `scoper` the answers and ask for a revised work order.
- **3 or more questions across 2 or more areas** → run a team. Launch one `fable-scoper-team` agent per area, at most 3, in ONE message, each named `scope-<area>`. Each prompt holds: the saved work order's absolute path, its area, its questions, and every teammate's name and area. In Opus mode pass `model: "opus"`. Start the stall timer. When every team member has returned, and again if one returns a revised report, wait until all are quiet, then SendMessage `scoper` all their reports in full and ask for a merged work order whose first line reads `Revised after team scoping: <areas>`. Any `Still open` item goes to the user with AskUserQuestion before Step 2.

**Log every decision, including `None`.** Append one line to `~/.claude/skills/scope-and-run3/team-decisions.log`:
`<YYYY-MM-DD> | <repo> | <request, under 60 chars> | questions=<N> areas=<M> | <none|settled|team> | <one-line reason>`
Tell the user the decision in one line. If `team` shows up on more than about 1 job in 20 in this log, the trigger is too loose and needs tightening.

### Step 1.5 — Spec check (Opus mode only)

Fable specs skip this. In Opus mode, before executing, launch a fresh `spec-checker` agent in the background (named `spec-checker`) with the work order as its prompt.

- CLEAN → proceed to Step 2.
- Discrepancies → send them back to the scoper for one revision, then re-check once. Still failing → surface to the user before executing anything.

## Step 2 — Execute

Follow the work order's **Execution plan**: one `work-order-executor` agent per track, passing the track's recommended `model` and `effort` as Agent-call overrides. Default to `model: "opus"` if the plan omits one. Before launching, tell the user the plan in one line per track: model, effort, files, parallel or serial.

**Optimize for wall-clock: hybrid fan-out (standing instruction, Alec 2026-08-22).** Independent tracks run in parallel, each in its own isolated worktree; only tracks that depend on another track's output run serially, on the merged tree. A final merge + one review is the accepted price of parallelism — conflicts are the orchestrator's job to resolve, not a reason to serialize.

- **Precondition — the branch must be committed.** Isolated worktrees fork from the last commit, so uncommitted work in this worktree will NOT be in them. If `git status` shows uncommitted changes the tracks depend on, tell the user in one line and ask: commit first (their call — you never commit), or run serial this once. The saved work order and any Step 0 `CONTEXT.md` or `docs/adr/` entries don't count: executors get the work order in their prompt.
- **Independent tracks** (the work order's Execution plan lists each track's files and dependencies): create one worktree per track YOURSELF from the branch HEAD (`git worktree add .claude/worktrees/<slug> -b claude/<slug> <HEAD-sha>` then `git -C … push -u origin claude/<slug>`), then launch all executors in ONE message, each told to `cd` into its worktree's absolute path first and verify `git rev-parse --short HEAD` matches. **Never use the Agent tool's `isolation: "worktree"` for branch work — it forks from `main`, not the current branch (observed 2026-08-22), so branch-only files are missing there.** Each runs only its own track's checks in its worktree. When they return, fold each track into this worktree without committing: `git -C <track-worktree> add -A --intent-to-add && git -C <track-worktree> diff HEAD --binary > <scratchpad>/<track>.patch`, then `git apply --3way <patch>` here. Resolve any conflict yourself (docs rows and shared test files are the usual ones); a conflict in real code means the scoper fenced files badly — fix the merge, note it for the review.
- **Dependent tracks** then run serially in this worktree on the merged result, with a handoff note describing what the merged tree now contains.
- **After the tracks merge, run the combined verification only when two tracks edited the same file or one track's filter names a suite that imports another track's module.** Otherwise the per-track greens stand and the commit guard is the next check. Build capacity is the ceiling (all tracks compile behind the same build lock), so expect queueing, not collisions.
- Never let two agents edit the same file in the same worktree; if a parallel track's files overlap another's, serialize just those two.

Each executor's prompt is the COMPLETE work order verbatim (all sections including Executor rules), plus "Your track: steps N–M."
The Executor rules include reading the nearest AGENTS.md before editing a folder; if a scoper's work order is missing that rule, add it to the handoff yourself. One handoff per executor, one message — never drip-feed or summarize the work order.

## Step 3 — Judge

Wait for ALL tracks to return before judging. Waiting means ending your turn until the app wakes you, not polling. Then:

- **Done claims count only if each track's filter was run and passed, plus the combined verification when the rule above calls for it, and that output is in a result you can see.** If missing, send one executor (via SendMessage) one instruction: run the verification commands and paste the output. No other commentary.
- If verification passed: proceed to Step 4.
- If any executor reported a spec/reality discrepancy: that is correct behavior. Relay the discrepancy to the SAME scoper used in Step 1 (`fable-scoper2`, `fable-scoper-quick2` or `opus-scoper2`) for a revised work order, then re-run Step 2 with FRESH executors for the affected track(s) only — completed clean tracks stand. Max one retry cycle; after that, surface the situation to the user.
- If an executor drifted (touched out-of-scope files, improvised): discard its result (`git checkout` its track's files if needed), report what happened, and ask the user whether to retry with a tightened work order.

## Step 4 — Review (final gate, conditional)

**Decide first whether review is warranted — from facts you already have, before spawning anything.** Run `git diff HEAD --stat` for the numbers.

**Review is REQUIRED if ANY of these hold:**
- More than one execution track ran (integration between tracks is exactly what per-track checks miss).
- Any retry, rescope, or reported discrepancy happened along the way.
- The diff exceeds ~150 changed lines or 3 files.
- The change touches concurrency, audio-thread code, device lifecycle, persistence/migration, security boundaries, or shared infrastructure other features depend on.
- The Verification commands don't directly exercise the changed behavior (e.g. "build passes" as the only check).
- Opus mode (weaker scoping means the back gate matters more).
- Any executor's report was vague, hedged, or didn't map cleanly onto the steps.

**Skip review only if ALL of these hold:** single track, clean first-pass execution, diff within the limits above, no risky-area files, and the pasted verification output directly tests the changed behavior. When skipping, tell the user in one line: "Skipped review: <which criteria>." If in doubt, review — a wasted review costs tokens; a missed defect costs a debugging session.

Launch a fresh `work-order-reviewer` agent in the background (named `reviewer`) with the work order and the executor's report as its prompt, plus one line naming the files the pipeline itself wrote (the saved work order, any Step 0 `CONTEXT.md` or `docs/adr/` entries) so it doesn't flag them as out of scope. Normal mode: default model (fable). **Opus mode:** pass `model: "opus"`, `effort: "medium"` as Agent-call overrides — then YOU filter its findings: keep spec violations, out-of-scope changes, and defects with a concrete failure scenario; drop hedged maybes with no scenario (Opus is told to report everything; filtering is your job).

- APPROVED (or review skipped) → report to the user: outcome first, what changed, pasted verification output, and either "Fable-reviewed"/"Opus-reviewed" or the skip reason.
- Problems → send them to a FRESH Opus executor as a fix-list appendix to the work order, then re-run Step 3 and Step 4 once. If it fails review twice, stop and surface everything to the user.

