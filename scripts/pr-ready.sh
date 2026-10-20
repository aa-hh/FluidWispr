#!/bin/bash
# Says whether a pull request may merge: the branch review passed on the PR's
# head commit, and CI's `Build FluidVoice` and `SwiftLint` check runs ended in
# success or skipped. .claude/hooks/require-merge-approval.py runs this before
# any merge, because GitHub enforces nothing on this repo (private, free plan).
#
# The review passes when the PR comment that scripts/review-branch.sh posted
# with the highest round, marker line
#   <!-- fluidwispr-review round=<n> head=<sha> level=<level> high=<k> changes=<id> -->
# names the PR head and high=0, or when the head has a `review` commit status
# of success. The comment counts on its own because the cloud proxy refuses
# status posts (HTTP 403).
#
# REST calls only (`gh api`): cloud sessions cannot use GraphQL, so no `gh pr`.
#
# Usage: bash scripts/pr-ready.sh [<pr-number>]   (default: the open PR for
#        the current branch)
# Prints one line per check. Exit: 0 every check passes; 1 a check fails;
# 2 the PR or its head commit cannot be found.
# GH overrides the gh command (for tests).

set -uo pipefail

GH=${GH:-gh}
REQUIRED_CHECKS=("Build FluidVoice" "SwiftLint")

repo=$(git remote get-url --push origin 2>/dev/null \
  | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##; s#/$##')
[ -n "$repo" ] || { echo "No origin remote, so the GitHub repo is unknown." >&2; exit 2; }

pr=${1:-}
if [ -z "$pr" ]; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || { echo "Detached HEAD and no PR number given." >&2; exit 2; }
  pr=$($GH api "repos/$repo/pulls?state=open&head=${repo%%/*}:$branch" --jq '.[0].number' 2>/dev/null)
  [ "$pr" = null ] && pr=""
  [ -n "$pr" ] || { echo "No open pull request for $branch." >&2; exit 2; }
fi
case "$pr" in *[!0-9]* | "") echo "Not a PR number: $pr" >&2; exit 2 ;; esac

sha=$($GH api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null)
case "$sha" in [0-9a-f]*) ;; *) echo "Could not read the head commit of PR #$pr." >&2; exit 2 ;; esac

failed=0

# Review: the highest-round marker on the PR, else a `review` status.
last=$($GH api --paginate "repos/$repo/issues/$pr/comments" --jq '.[].body' 2>/dev/null \
  | grep '^<!-- fluidwispr-review round=[0-9]' \
  | sed 's/^<!-- fluidwispr-review round=\([0-9]*\)/\1	&/' | sort -n | tail -n 1 | cut -f2-)
field() { printf '%s\n' "$last" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
m_round=$(field round); m_head=$(field head); m_high=$(field high)
if [ -n "$last" ] && [ "$m_head" = "$sha" ] && [ "$m_high" = 0 ]; then
  echo "review: ok (round $m_round, comment)"
elif [ "$($GH api "repos/$repo/commits/$sha/status" \
          --jq '.statuses[] | select(.context == "review") | .state' 2>/dev/null | head -n 1)" = success ]; then
  echo "review: ok (status)"
elif [ -n "$last" ] && [ "$m_head" = "$sha" ]; then
  echo "review: $m_high HIGH open"; failed=1
else
  echo "review: missing for head ${sha:0:12}"; failed=1
fi

# CI: the latest check run per name (the endpoint's default filter).
runs=$($GH api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
  --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv' 2>/dev/null)
for name in "${REQUIRED_CHECKS[@]}"; do
  row=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" '$1 == n { print; exit }')
  if [ -z "$row" ]; then
    echo "$name: missing"; failed=1; continue
  fi
  conclusion=$(printf '%s\n' "$row" | cut -f3)
  case "$conclusion" in
    success | skipped) echo "$name: $conclusion" ;;
    "") echo "$name: $(printf '%s\n' "$row" | cut -f2)"; failed=1 ;;
    *) echo "$name: $conclusion"; failed=1 ;;
  esac
done

exit "$failed"
