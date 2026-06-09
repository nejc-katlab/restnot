#!/bin/bash
#
# Registers the RestNot Claude Code hook in ~/.claude/settings.json by appending
# a hook group to each relevant event array. Existing hooks are preserved. Safe
# to re-run: events that already reference the RestNot hook are skipped.

set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
HOOK_CMD="~/.restnot/restnot-hook.sh"

if [ ! -f "$SETTINGS" ]; then
  echo "No settings.json found at $SETTINGS" >&2
  exit 1
fi

cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"

SETTINGS="$SETTINGS" HOOK_CMD="$HOOK_CMD" python3 - <<'PY'
import os, json

path = os.environ["SETTINGS"]
cmd = os.environ["HOOK_CMD"]
events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
added = []
for event in events:
    arr = hooks.setdefault(event, [])
    present = any(
        any(h.get("command") == cmd for h in group.get("hooks", []))
        for group in arr
    )
    if not present:
        arr.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
        added.append(event)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("RestNot hook registered on:", ", ".join(added) if added else "(already present everywhere)")
PY
