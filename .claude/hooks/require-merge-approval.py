#!/usr/bin/env python3
"""PreToolUse gate: pause for a human before any `git merge` into main.

WHY THIS EXISTS
---------------
There was never a stored setting that made agents "ask before merging" — that
was just Claude Code's default interactive prompt on a non-allowlisted Bash
command. Autonomous agents (teammates / workflows / background runs) execute
Bash WITHOUT that per-command prompt, so once merges started being landed by
autonomous agents, they stopped surfacing to the human. A PreToolUse hook is
the one layer that still fires for those agents, so this is where the gate has
to live.

WHAT IT DOES
------------
Fires on the Bash tool. If the command runs `git merge` and the branch that
would receive the merge is main/master, it DENIES the command unless the
owner opened a merge window (see below).
Merging main INTO a work branch passes without asking (owner's call,
2026-10-03): it only changes that branch, and the branch still needs approval
to land on main. Whenever the receiving branch can't be worked out — a
checkout/switch in the same command, an unparseable command, detached HEAD,
git failing — it treats the merge as one into main.

Since 2026-10-04 main only takes pull requests, so a merge no longer looks like
`git merge`: it is `gh pr merge` (often `--auto`, which lands the PR later with
no one watching), `gh api .../pulls/N/merge`, or the app's auto-merge switch
(mcp__ccd_pr__set_auto_merge, wired by its own matcher in settings.json). All
three are gated too (owner's call, 2026-10-04).

Deny, not ask (2026-10-04): a bypass-permissions session approves an "ask"
without showing it, so `gh pr merge --auto` ran with no prompt. The gate now
lets a merge through only inside a 30-minute window that
record-merge-approval.py (a UserPromptSubmit hook) opens when the owner's own
typed message says to merge, in that same session. Outside that window it
opens a macOS Deny / Merge dialog and waits up to 5 minutes for the owner's
click (owner's call, 2026-10-04: "both"); no answer counts as Deny.

FLUIDWISPR COPY (2026-10-21)
----------------------------
This copy lives in the repo (.claude/hooks/) so it also runs in cloud sessions
(claude.ai/code), where the owner's personal hooks are not installed. The repo
is private on GitHub's free plan, so GitHub offers no branch protection or
required checks: nothing server-side stops a push to main or a merge of an
unreviewed PR. The cloud's GitHub proxy also refuses GraphQL, so `gh pr merge`
fails there and merges go through `gh api .../pulls/N/merge`. Three changes:

- Pushes to main are denied outright, with no window and no dialog: any
  `git push` naming main (`main`, `x:main`, `refs/heads/main`, `+main`), or
  pushing every branch (`--all`, `--branches`, `--mirror`), or naming no
  branch or `HEAD` while the current branch is main. The repo's .githooks/pre-push refuses these too.
- Before the approval step, a PR merge must pass `bash scripts/pr-ready.sh <n>`
  (review comment or status on the PR head, plus the Build FluidVoice and
  SwiftLint check runs). A failure denies at once. A repo without the script
  skips this step.
- The dialog opens only on macOS (sys.platform == "darwin"); elsewhere no
  answer counts as Deny. MERGE_GATE_NO_DIALOG=1 skips the dialog everywhere;
  it is for tests only.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time

MERGE_RE = re.compile(r"""\bgit\s+(-C\s+("[^"]*"|'[^']*'|\S+)\s+)?merge(?![-\w])""")
PROTECTED = {"main", "master"}


APPROVAL_DIR = os.path.expanduser("~/.claude/state/merge-approval")
WINDOW_S = 30 * 60


def approved() -> bool:
    sid = re.sub(r"[^\w-]", "_", data.get("session_id") or "")
    try:
        with open(os.path.join(APPROVAL_DIR, sid)) as f:
            return time.time() - int(f.read().strip()) < WINDOW_S
    except Exception:
        return False


DIALOG_S = 300  # settings.json gives this hook 330 s, so the dialog gives up first
DIALOG = """on run argv
display dialog (item 1 of argv) with title "Merge into main?" buttons {"Deny", "Merge"} \
default button "Deny" cancel button "Deny" giving up after (item 2 of argv as integer) with icon caution
end run"""


def owner_clicked_merge() -> bool:
    """macOS dialog the owner answers. Deny, a timeout, any failure, a
    non-macOS host or MERGE_GATE_NO_DIALOG=1 (tests only) = False."""
    if sys.platform != "darwin" or os.environ.get("MERGE_GATE_NO_DIALOG") == "1":
        return False
    what = (data.get("tool_input") or {}).get("command") or json.dumps(data.get("tool_input") or {})
    text = (f"An agent wants to merge into main.\n\nFolder: {data.get('cwd') or '?'}\n\n"
            f"{what[:600]}")
    try:
        out = subprocess.run(["osascript", "-e", DIALOG, text, str(DIALOG_S)],
                             capture_output=True, text=True, timeout=DIALOG_S + 15).stdout
    except Exception:
        return False
    return "button returned:Merge" in out and "gave up:true" not in out


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def ask(reason: str) -> None:
    """Gate a merge into main: allow inside the owner's typed-"merge" window or
    on the owner's click in the dialog, else deny."""
    if approved() or owner_clicked_merge():
        sys.exit(0)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason + " BLOCKED: the owner denied it or did not "
                "answer the merge dialog, and has not typed a message saying to merge in "
                "this session in the last 30 minutes. Stop and ask the owner. Never write "
                "the approval file yourself and never retry another way.",
        }
    }))
    sys.exit(0)


def merge_dir(cmd: str, cwd: str) -> str | None:
    """Folder the first `git merge` runs in, following `cd` and `git -C`.

    None = unsure (unparseable, or a `git checkout`/`git switch` runs first and may
    change the receiving branch). "" = no real `git merge` command after all.
    """
    try:
        toks = tokens(cmd)
    except ValueError:
        return None
    d = cwd
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "cd":
            if i + 1 >= len(toks):
                return None
            d = os.path.join(d, os.path.expanduser(toks[i + 1]))
            i += 2
            continue
        if t == "git":
            j = i + 1
            gd = d
            if j + 1 < len(toks) and toks[j] == "-C":
                gd = os.path.join(d, os.path.expanduser(toks[j + 1]))
                j += 2
            if j < len(toks) and toks[j] == "merge":
                return gd
            if j < len(toks) and toks[j] in ("checkout", "switch"):
                return None
        i += 1
    return ""


SEPARATORS = {";", "&&", "||", "|", "&", "(", "$(", "`", "\n", "then", "do", "else"}
HEREDOC = re.compile(r"""<<-?[ \t]*(['"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)""", re.S)


def tokens(cmd: str) -> list[str]:
    """Shell words with newlines kept as separators and heredoc bodies dropped.
    A heredoc body is text, not commands. razor: a merge fed to `bash <<EOF`
    slips through; gate that too if agents ever start doing it."""
    cmd = HEREDOC.sub("<<HEREDOC", cmd)
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="();<>|&\n`$")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    return list(lex)


def gh_pr_merge(cmd: str) -> bool:
    """True when the command runs `gh pr merge` (bare or --auto) or merges a PR
    through `gh api .../pulls/N/merge`. `gh pr merge --disable-auto` passes: it
    only takes a PR back out of the queue. Unparseable → True (ask)."""
    if "gh" not in cmd or "merge" not in cmd:
        return False
    try:
        toks = tokens(cmd)
    except ValueError:
        return True
    for i, t in enumerate(toks):
        # Only `gh` where a command starts, so prose that quotes the command
        # (a commit message, a note) is not mistaken for running it.
        if t != "gh" or (i and toks[i - 1] not in SEPARATORS):
            continue
        rest = toks[i + 1:]
        if rest[:2] == ["pr", "merge"]:
            tail = []
            for r in rest[2:]:
                if r in (";", "&&", "||", "|", "&"):
                    break
                tail.append(r)
            if "--disable-auto" not in tail:
                return True
        if rest[:1] == ["api"] and any(re.search(r"pulls/\d+/merge\b", r) for r in rest):
            return True
    return False


PUSH_FLAGS_WITH_VALUE = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def pushes_to_main(cmd: str, cwd: str) -> bool:
    """True when a `git push` in the command would update main, following `cd`
    and `git -C` to find the branch a refspec-less push sends. Unparseable
    with a push in it = True."""
    if "push" not in cmd:
        return False
    try:
        toks = tokens(cmd)
    except ValueError:
        return bool(re.search(r"\bgit\b.*\bpush\b", cmd))
    d = cwd
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "cd" and i + 1 < len(toks):
            d = os.path.join(d, os.path.expanduser(toks[i + 1]))
            i += 2
            continue
        if t != "git":
            i += 1
            continue
        j = i + 1
        gd = d
        if j + 1 < len(toks) and toks[j] == "-C":
            gd = os.path.join(d, os.path.expanduser(toks[j + 1]))
            j += 2
        if j >= len(toks) or toks[j] != "push":
            i = j
            continue
        args, k = [], j + 1
        while k < len(toks) and toks[k] not in SEPARATORS:
            args.append(toks[k])
            k += 1
        positional, flags, skip = [], set(), False
        for a in args:
            if skip:
                skip = False
            elif a in PUSH_FLAGS_WITH_VALUE:
                skip = True
            elif a.startswith("-"):
                flags.add(a.split("=", 1)[0])
            else:
                positional.append(a)
        for a in positional:
            r = a.lstrip("+")
            if r in ("main", "refs/heads/main") or r.endswith((":main", ":refs/heads/main")):
                return True
        if flags & {"--all", "--branches", "--mirror"}:
            return True  # pushes every local branch, main included
        refspecs = positional[1:]
        if not refspecs or "HEAD" in [r.lstrip("+") for r in refspecs]:
            if current_branch(gd) in ("main", ""):
                return True
        i = k
    return False


def current_branch(d: str) -> str:
    try:
        return subprocess.run(["git", "-C", d, "symbolic-ref", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def gh_dir(cmd: str, cwd: str) -> str:
    """Folder the first `gh` runs in, following `cd`."""
    try:
        toks = tokens(cmd)
    except ValueError:
        return cwd
    d = cwd
    for i, t in enumerate(toks):
        if t == "cd" and i + 1 < len(toks):
            d = os.path.join(d, os.path.expanduser(toks[i + 1]))
        if t == "gh":
            break
    return d


def merge_pr_number(cmd: str) -> str:
    """The PR a merge command names: `pulls/N/merge`, else the first bare
    integer after `gh pr merge`; "" when it names none."""
    m = re.search(r"pulls/(\d+)/merge\b", cmd)
    if m:
        return m.group(1)
    try:
        toks = tokens(cmd)
    except ValueError:
        return ""
    for i, t in enumerate(toks):
        if t == "gh" and toks[i + 1:i + 3] == ["pr", "merge"]:
            for r in toks[i + 3:]:
                if r in SEPARATORS:
                    break
                if r.isdigit():
                    return r
    return ""


def require_ready(pr: str, d: str) -> None:
    """Deny unless scripts/pr-ready.sh passes for the PR. No script = no check."""
    repo = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    if not repo:
        try:
            repo = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                                  capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            repo = ""
    script = os.path.join(repo, "scripts", "pr-ready.sh") if repo else ""
    if not script or not os.path.isfile(script):
        return
    try:
        r = subprocess.run(["bash", script] + ([pr] if pr else []), cwd=d if os.path.isdir(d) else repo,
                           capture_output=True, text=True, timeout=90)
        code, out = r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        code, out = 1, f"scripts/pr-ready.sh did not finish: {e}"
    if code != 0:
        deny(f"{out}\nFix the review or CI status first; the merge gate only opens when "
             "scripts/pr-ready.sh passes.")


try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # unparseable input → never interfere

PR_REASON = ("This merges a pull request on GitHub, or queues it to merge on its own "
             "once checks pass. Merges into main require explicit human go-ahead — "
             "confirm before landing (this gate also covers autonomous agents).")

cwd = data.get("cwd") or os.getcwd()
tool_input = data.get("tool_input") or {}

if data.get("tool_name") == "mcp__ccd_pr__set_auto_merge":
    n = next((str(v) for k, v in tool_input.items()
              if k in ("pr", "pr_number", "number", "pull_number") and str(v).isdigit()), "")
    require_ready(n, cwd)
    ask(PR_REASON)

cmd = tool_input.get("command", "") or ""
if pushes_to_main(cmd, cwd):
    deny("This pushes to main. main changes only through a merged pull request; the "
         "pre-push hook refuses this too. Push a branch and open a PR instead.")
if gh_pr_merge(cmd):
    require_ready(merge_pr_number(cmd), gh_dir(cmd, cwd))
    ask(PR_REASON)
if not MERGE_RE.search(cmd):
    sys.exit(0)

reason = ("This runs `git merge` into {}. Merges into main require explicit human "
          "go-ahead — confirm before landing (this gate also covers autonomous agents).")

d = merge_dir(cmd, cwd)
if d is None:
    ask(reason.format("a branch this hook couldn't identify, or one this command switches to"))
if d == "":
    sys.exit(0)  # "merge" appeared only as text (commit message, branch name)

try:
    branch = subprocess.run(
        ["git", "-C", d, "symbolic-ref", "--short", "HEAD"],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip()
except Exception:
    branch = ""

if not branch or branch in PROTECTED:
    ask(reason.format(branch or "an unknown branch"))

sys.exit(0)  # merging into a work branch: no gate
