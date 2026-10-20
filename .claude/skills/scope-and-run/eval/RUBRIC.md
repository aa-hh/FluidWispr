# Grading task: /scope-and-run outcomes

You grade past Claude Code sessions in which the user (Alec) ran /scope-and-run (or the trial versions /scope-and-run2, /scope-and-run3). The pipeline: a Fable "scoper" agent writes a work order (verified facts with file:line, numbered steps, scope fences, verification commands) -> Opus "executor" agents build each track -> orchestrator judges (done only if verification output is visible) -> optional "work-order-reviewer" gate -> final report. The skill's stated quality bar: executors do exactly the work order, no drift; "done" only with real passing verification output; reviewer catches spec violations and real defects; final report is honest; result should be close to production-ready (mergeable with little/no rework).

Inputs per session:
- Digest: $SAR_WORK/digests/NNN.md (compact; long sessions have the middle trimmed).
- Raw transcript: ~/.claude/projects/<file named on the digest's first line>. Subagent transcripts (scoper, executors, reviewer) are in the sibling folder <session-id>/subagents/*.jsonl. Use `grep`/`python3 -I` on the raw files when the digest is trimmed or unclear, especially to find the reviewer verdict and what Alec said AFTER the pipeline's final report.
- Strongest evidence of real quality is what happened AFTER the pipeline said done: Alec accepting/committing/merging/moving on = good; Alec reporting bugs, "this doesn't work", "you missed X", asking for redo, a later review-branch or PR review finding HIGH issues, or follow-up fix rounds = shortfall. Also check whether the pipeline's own reviewer found problems (gate working) and whether "done" claims were later proven false.

A session may contain zero, one, or several runs. Grade each run separately. A "run" = one invocation of the skill on one request.

Per run, output a JSON object:
{
 "session": "NNN",
 "run": 1,
 "skill_version": "scope-and-run|scope-and-run2|scope-and-run3",
 "date": "YYYY-MM-DD",
 "repo": "short repo name",
 "request": "<=20 words, what was asked",
 "task_size": "small|medium|large",
 "grade": "A|B|C|D|X",
   // A = production-ready: passed its gates, Alec accepted with no follow-up fixes to this work
   // B = close: Alec needed one small follow-up fix/tweak (a few lines or one round) after "done"
   // C = fell short: "done" reported but real defects / spec misses / wrong behaviour found afterwards, or substantial rework needed
   // D = pipeline failed: stalled, aborted, abandoned, or never produced working code
   // X = not gradeable: skill never actually executed (only mentioned/loaded), or session ends before the outcome is knowable
 "confidence": "high|medium|low",
 "reviewer_ran": true/false, "reviewer_found_issues": true/false/null, "fix_rounds_inside_pipeline": 0,
 "false_done_claim": true/false/null,   // pipeline/executor said done+verified but it was not
 "failure_causes": [ ...zero or more of: "scoper_wrong_fact", "scoper_missed_requirement", "scoper_misread_intent", "spec_ambiguous", "executor_drift_or_scope_creep", "executor_incomplete", "weak_verification" (checks did not exercise the behaviour, e.g. build-only or UI never looked at), "reviewer_missed_defect", "orchestrator_broke_rules" (edited code itself, skipped gates, summarized work order), "stall_or_infra" (hung agents, capacity, worktree/merge trouble), "merge_or_integration", "ui_visual_quality" (looked wrong/AI-ish though code ran), "user_changed_mind" (not the pipeline's fault), "other:<text>" ],
 "evidence": "1-3 sentences with concrete quotes/facts: what happened after done, what was wrong",
 "cost_signals": "agents launched, retries, rough wall time if visible"
}

Rules: grade from evidence, not from the pipeline's own claims. If the session ends right after the final report with no further sign, grade by the reviewer verdict + verification quality and set confidence "low". Be terse. Do not modify any file except your output file.
