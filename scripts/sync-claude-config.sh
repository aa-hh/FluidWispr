#!/bin/bash
# Copies Alec's personal Claude Code setup into this repo's .claude/ so cloud
# sessions (claude.ai/code), which never see ~/.claude, get the same
# instructions, skills, agents, output style and hooks. Re-run after changing
# the personal config, then commit the result.
# Source: $CLAUDE_CONFIG_DIR, default ~/Projects/claude-config.
set -eu

src=${CLAUDE_CONFIG_DIR:-$HOME/Projects/claude-config}
root=$(cd "$(dirname "$0")/.." && pwd)
dst=$root/.claude
mkdir -p "$dst/skills" "$dst/agents" "$dst/output-styles" "$dst/hooks"

cp "$src/CLAUDE.md" "$dst/global-instructions.md"
echo "copied CLAUDE.md -> .claude/global-instructions.md"

rsync -a --delete --exclude synced "$src/skills/" "$dst/skills/"
echo "copied skills/ -> .claude/skills/"

rsync -a --delete "$src/agents/" "$dst/agents/"
echo "copied agents/ -> .claude/agents/"

cp "$HOME/.claude/output-styles/terse.md" "$dst/output-styles/terse.md"
echo "copied ~/.claude/output-styles/terse.md -> .claude/output-styles/terse.md"

# Only the hooks that work unchanged in this repo. require-merge-approval.py
# has a FluidWispr-specific copy; the others are local-machine only.
for h in agents-md-nudge.py subagent-comms-rules.py plan-intent.sh record-merge-approval.py; do
  cp "$src/hooks/$h" "$dst/hooks/$h"
  echo "copied hooks/$h -> .claude/hooks/$h"
done

python3 - "$src/settings.json" "$dst/cloud-plugins.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
local = {k for k, v in s.get("extraKnownMarketplaces", {}).items()
         if v.get("source", {}).get("source") == "directory"}
markets = {k: v for k, v in s.get("extraKnownMarketplaces", {}).items() if k not in local}
markets.setdefault("claude-plugins-official",
                   {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}})
plugins = {k: v for k, v in s.get("enabledPlugins", {}).items()
           if k.rpartition("@")[2] not in local}
json.dump({"enabledPlugins": plugins, "extraKnownMarketplaces": markets},
          open(sys.argv[2], "w"), indent=2)
open(sys.argv[2], "a").write("\n")
PY
echo "wrote enabledPlugins + extraKnownMarketplaces -> .claude/cloud-plugins.json"
