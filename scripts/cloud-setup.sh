#!/bin/bash
# Setup script for the claude.ai/code cloud environment. The environment's
# setup script field runs `bash scripts/cloud-setup.sh` as root (HOME=/root)
# before Claude Code starts. It installs the personal config vendored in
# .claude/ (see scripts/sync-claude-config.sh) into ~/.claude, adds the
# plugins, and turns on the repo's git hooks.
# Never exits non-zero: a failed step must not block the session.

root=$(cd "$(dirname "$0")/.." && pwd)
plugins_json=$root/.claude/cloud-plugins.json

# Plugin stage, run as a child under `timeout` (see below).
if [ "${1:-}" = --plugins ]; then
  out=$(mktemp -d)
  while read -r src; do
    [ -n "$src" ] || continue
    (claude plugin marketplace add "$src" > /dev/null 2>&1 && echo "$src" > "$out/m.$RANDOM$RANDOM") &
  done < <(python3 -c 'import json,sys
for m in json.load(open(sys.argv[1])).get("extraKnownMarketplaces", {}).values():
    s = m.get("source", {}); print(s.get("repo") or s.get("url") or "")' "$plugins_json")
  wait
  while read -r p; do
    (claude plugin install "$p" --yes > /dev/null 2>&1 && echo "$p" > "$out/p.$RANDOM$RANDOM") &
  done < <(python3 -c 'import json,sys
for k, v in json.load(open(sys.argv[1])).get("enabledPlugins", {}).items():
    v and print(k)' "$plugins_json")
  wait
  m=$(cat "$out"/m.* 2>/dev/null | wc -l | tr -d ' ')
  p=$(cat "$out"/p.* 2>/dev/null | wc -l | tr -d ' ')
  echo "plugins: $m marketplaces added, $p plugins installed:" $(cat "$out"/p.* 2>/dev/null)
  rm -rf "$out"
  exit 0
fi

mkdir -p ~/.claude/output-styles || true
cp "$root/.claude/global-instructions.md" ~/.claude/CLAUDE.md || true
cp "$root/.claude/output-styles/terse.md" ~/.claude/output-styles/ || true

python3 - "$plugins_json" <<'PY' || true
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
try:
    s = json.load(open(path))
except (OSError, ValueError):
    s = {}
try:
    p = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    p = {}
s["outputStyle"] = "Terse"
s["effortLevel"] = "high"
s.setdefault("env", {})["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
s.setdefault("enabledPlugins", {}).update(p.get("enabledPlugins", {}))
s.setdefault("extraKnownMarketplaces", {}).update(p.get("extraKnownMarketplaces", {}))
json.dump(s, open(path, "w"), indent=2)
print("wrote", path)
PY

if command -v claude > /dev/null 2>&1; then
  if command -v timeout > /dev/null 2>&1; then
    timeout 120 bash "$root/scripts/cloud-setup.sh" --plugins || echo "plugin stage stopped after 120s or failed"
  else
    bash "$root/scripts/cloud-setup.sh" --plugins || true
  fi
else
  echo "claude CLI not on PATH; plugins skipped"
fi

git -C "$root" config core.hooksPath .githooks || true
echo "cloud-setup done"
exit 0
