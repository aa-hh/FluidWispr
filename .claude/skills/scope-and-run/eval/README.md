# Grading past /scope-and-run runs

Baseline (2026-10-08, runs 2026-08-07 to 2026-10-07): 120 runs, A 42%, B 21%, C 33%, D 4%. Large tasks: A 22%. Raw grades in `baseline-2026-10-08/`.

To grade new runs after changing the skill:

1. `SAR_SINCE=2026-10-09 python3 -I index.py` lists sessions that ran the skill (set `SAR_SKIP_SESSION=<id>` to leave out the session doing the grading).
2. `python3 -I digest.py` writes one short digest per session to `work/digests/`.
3. Start Opus grading agents, about 19 digests each: "Read RUBRIC.md and follow it exactly. Your sessions: digests NNN through MMM. Write a JSON array to work/grades/batchK.json." Replace `$SAR_WORK` in RUBRIC.md with the real `work/` path in the prompt.
4. `python3 -I aggregate.py` prints the rates. Compare the share of A grades with the baseline.
