#!/usr/bin/env bash
# UserPromptSubmit hook: detect a planning request and inject guidance to route it
# through the `planner` sub-agent workflow (research -> confirm ambiguities -> plan).
# Matches: the literal "/plan", OR a planning verb within ~40 chars of the word "plan".
# Pure shell (no jq/python/node dependency): greps the raw stdin payload and emits a
# fixed JSON string. Stays tight so casual uses of "plan" don't trigger it.

raw="$(cat)"
[ -z "$raw" ] && exit 0
text="$(printf '%s' "$raw" | tr '\n' ' ')"

if printf '%s' "$text" | grep -qiE '(^|[^[:alnum:]])/plan([^[:alnum:]]|$)|(make|create|draft|come up with|put together|lay out|write up|build( out)?|produce|develop|devise|generate|outline)[^.]{0,40} plan\b'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"PLANNING REQUEST detected. Do NOT plan inline yourself. Delegate to the `planner` sub-agent (it runs on Opus at high effort and carries the full planning contract). When it returns: if it lists an OPEN QUESTIONS - needs confirmation section, ASK the user those via AskUserQuestion BEFORE finalizing - never resolve an ambiguity by assumption, since the user prefers answering specifics over having you guess. Then present the final plan (task list with per-task model + effort, parallelization waves + critical path, and risks) and wait for approval before implementing."}}
JSON
fi
exit 0
