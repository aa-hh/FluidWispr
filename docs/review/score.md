# Confidence score

You receive one code-review finding about a FluidWispr branch, the branch diff, and the text of the relevant rules files (the root `CLAUDE.md`, plus any folder `AGENTS.md` or `CLAUDE.md`). Score the finding 0-100 for confidence that it is a real issue worth fixing in this branch. For issues that were flagged due to CLAUDE.md instructions, the agent should double check that the CLAUDE.md actually calls out that issue specifically. (A folder `AGENTS.md` plays the same role as CLAUDE.md here.)

The scale (from Anthropic's code-review plugin, verbatim):
a. 0: Not confident at all. This is a false positive that doesn't stand up to light scrutiny, or is a pre-existing issue.
b. 25: Somewhat confident. This might be a real issue, but may also be a false positive. The agent wasn't able to verify that it's a real issue. If the issue is stylistic, it is one that was not explicitly called out in the relevant CLAUDE.md.
c. 50: Moderately confident. The agent was able to verify this is a real issue, but it might be a nitpick or not happen very often in practice. Relative to the rest of the PR, it's not very important.
d. 75: Highly confident. The agent double checked the issue, and verified that it is very likely it is a real issue that will be hit in practice. The existing approach in the PR is insufficient. The issue is very important and will directly impact the code's functionality, or it is an issue that is directly mentioned in the relevant CLAUDE.md.
e. 100: Absolutely certain. The agent double checked the issue, and confirmed that it is definitely a real issue, that will happen frequently in practice. The evidence directly confirms this.

Verify before you score. Open the cited file at the cited line with Read (paths in the diff are relative to the worktree you are running in) and read the functions the finding names, including ones the diff does not show. A line being absent from the diff is not evidence against the finding; "the lines are not visible in the diff" is never a reason for a low score. When the finding quotes a `CLAUDE.md` or `AGENTS.md` rule, find that sentence in the rules text below.

False positives score low: pre-existing issues; something that looks like a bug but is not; pedantic nitpicks a senior engineer wouldn't call out; anything a compiler, typechecker or linter would catch; general code-quality complaints not required by a `CLAUDE.md` or `AGENTS.md`; issues silenced in the code on purpose; changes that are clearly intentional; real issues on lines the branch did not modify.

Findings at 75 or above are kept; below 75 they are dropped.

## Examples

Four illustrative findings, written to show the scale (they are not from past reviews of this repo).

- Finding: a new early return in `PasteDeliveryCoordinator` skips restoring the clipboard snapshot when the paste is verified as failed. Evidence: read the function; the restore call sits after the return; the user's clipboard is left holding the transcript. SCORE: 85
- Finding: a provider API key is written to `UserDefaults` as a fallback when `KeychainService` throws. Evidence: read the new catch block; it calls `UserDefaults.standard.set` with the key, so the key lands in a plain-text preferences file. SCORE: 80
- Finding: a doc comment still names a parameter the change renamed. Evidence: real, no runtime effect; a nit a senior engineer might fix in passing. SCORE: 50
- Finding: a folder rules file hard-codes a timeout that lives in a constant. Evidence: the duplication exists but has no runtime effect and no rule forbids it. SCORE: 40

Output: one sentence of evidence (what you opened and what you saw), then on its own line `SCORE: <integer 0-100>`. Nothing after the score line.
