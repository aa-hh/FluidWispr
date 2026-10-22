# FluidWispr

Alec's macOS dictation app (Xcode project `Fluid.xcodeproj`, XCTest), started from a copy of altic-dev/FluidVoice. FluidWispr is its own app now and does not merge upstream: take model updates from FluidVoice at most, and port a FluidVoice fix by hand only when it is worth it.

Follow the writing rules in `.claude/global-instructions.md`: no invented terms, no em dashes, plain words.

## Build and test

- Compile: `./build.sh unsigned`
- Full tests, the same command CI runs:

```
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Tests must never show anything on Alec's screen. Every test run launches the full app, so `Sources/Fluid/Services/TestHost.swift` hides it: no Dock icon, no app startup, and every window is drawn at opacity 0 while code still reads the opacity it set. Never work around it. Don't launch a test build with `open` or by running its binary, and don't call `NSApp.setActivationPolicy` or `TransformProcessType` without checking `TestHost.isActive` first.

Cloud sessions run on Linux with no Xcode. There, edit and push, and let the `Build and Test` workflow on GitHub be the test run.

## Guards

Turn them on once per clone with `git config core.hooksPath .githooks`. The repo's SessionStart hook does this too.

pre-commit:
- Guard 1: no commits on `main`.
- Guard 3 (warn only): new test lines that reach `UserDefaults.standard` or the shared temp directory. Escape: `isolation-ok`.
- Guard 4: compile check when Swift under `Sources/` or `Tests/` is staged. Set `FLUID_FULL_SUITE=1` for the full xcodebuild test run. Skipped where xcodebuild is missing.
- Guard 7: screens new comments for filler. Escape: `slop-ok`.
- Guard 11: test rules in `Tests/`. Each new `func test…` needs a sentence above it saying what change turns it red. No `print(` in tests, no new file holding one test, no real-time waits. Escapes: `print-ok`, `new-suite-ok`, `real-time-ok: <reason>`.
- Guard 12: AGENTS.md rules.

pre-push refuses any push to `main`.

## Workflow

Locally, work in a worktree, never in the main checkout; a hook asks before any write there. Cloud sessions work in their own clone and skip the worktree step.

1. `git fetch origin && git worktree add .claude/worktrees/<slug> -b claude/<slug> origin/main && cd .claude/worktrees/<slug>` (cloud: `git switch -c claude/<slug> origin/main`)
2. Push the branch early: `git push -u origin HEAD`
3. Open the PR through the REST API, because cloud sessions cannot use `gh pr`:
   `gh api repos/aa-hh/FluidWispr/pulls -f title=... -f head=<branch> -f base=main -F body=@pr-body.md`
4. Run `bash scripts/review-branch.sh`. Run the review passes it prints as subagents, then run it again with `--continue`. It posts one PR comment holding the result; that comment is the record. It also posts the `review` commit status when GitHub allows it (cloud sessions cannot write statuses). Two rounds at most; only HIGH findings fail.

## Merging

GitHub's ruleset makes `main` take pull requests only, with the `Build FluidVoice` and `SwiftLint` checks required. The `review` check cannot be a GitHub status, because cloud sessions cannot write statuses, so the merge-approval hook enforces it. The hook refuses a merge unless `bash scripts/pr-ready.sh <pr>` passes: the latest review comment covers the PR head with no HIGH finding open (or a `review` status is success on it), and the `Build FluidVoice` and `SwiftLint` check runs are success or skipped. No typed go-ahead from Alec is needed: in this project a PR merges as soon as it is reviewed, fixed and green.

Merge with `gh api -X PUT repos/aa-hh/FluidWispr/pulls/<n>/merge -f merge_method=merge`. This works in the cloud and locally; `gh pr merge` uses GraphQL and fails in the cloud. Keep `-X PUT`: GitHub's merge endpoint takes PUT only, and without it `gh api` sends POST and GitHub answers 404 Not Found.

Merge your own PRs once `pr-ready.sh` passes. Never push to `main`.

## Cloud environment

- Setup script: `bash scripts/cloud-setup.sh`
- `scripts/sync-claude-config.sh` refreshes the copy of Alec's personal config from `~/Projects/claude-config`.
- The copies live in `.claude/`: global-instructions.md, skills, agents, output-styles, hooks, cloud-plugins.json.
