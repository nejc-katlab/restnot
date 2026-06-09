#!/bin/bash
#
# Generic agent -> RestNot hook adapter.
#
# Bridges any agentic CLI's hook system to RestNot's lease CLI so the Mac stays
# awake only while a turn is actively running. Tested with Codex CLI, Cursor,
# and Gemini CLI, but works with anything that can run a command on its
# turn-start and turn-stop events.
#
# Usage (from the tool's hook config):
#   restnot-agent-hook.sh <tool> busy     # on turn-start / tool-use events
#   restnot-agent-hook.sh <tool> stop     # on turn-end / session-end events
#
# The role (busy|stop) is passed explicitly so this works even for tools that
# don't put an event name on stdin. The session id is read from stdin JSON
# (session_id or conversation_id) or from env (GEMINI_SESSION_ID), so each
# concurrent session gets its own lease. The lease TTL is a safety net: if the
# tool dies mid-turn without firing a stop event, the lease still expires.

set -euo pipefail

tool="${1:-agent}"
role="${2:-busy}"

dir="$(cd "$(dirname "$0")" && pwd)"
RESTNOT="${RESTNOT_BIN:-$(command -v restnot 2>/dev/null || echo "${dir}/../bin/restnot")}"

input="$(cat 2>/dev/null || true)"

field() {
  printf '%s' "$input" \
    | /usr/bin/sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" \
    | head -n1
}

id="$(field session_id)"
[ -z "$id" ] && id="$(field conversation_id)"
[ -z "$id" ] && id="${GEMINI_SESSION_ID:-}"
[ -z "$id" ] && id="default"

key="${tool}-${id}"

case "$role" in
  stop) "$RESTNOT" release "$key" ;;
  *)    "$RESTNOT" lease "$key" ;;
esac

exit 0
