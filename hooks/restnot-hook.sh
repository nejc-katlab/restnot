#!/bin/bash
#
# RestNot Claude Code hook.
#
# Reads a Claude Code hook event from stdin and refreshes (or clears) a
# per-session lease file. RestNot holds a sleep assertion while any lease is
# unexpired, so the Mac stays awake only while an agent is actively working.
#
# "Busy" events (UserPromptSubmit, PreToolUse, PostToolUse, …) push the lease
# expiry to now + BUSY_TTL. "Idle" events (Stop, SessionEnd) remove the lease.
# The TTL is a safety net: if Claude Code dies mid-turn and never fires Stop,
# the lease still expires and the Mac is allowed to sleep again.
#
# Install: copy this script to ~/.restnot/restnot-hook.sh, make it executable,
# and register it in ~/.claude/settings.json (see hooks/settings.example.json).

LEASE_DIR="${HOME}/.restnot/leases"
BUSY_TTL="${RESTNOT_BUSY_TTL:-900}"

input="$(cat)"

extract() {
  printf '%s' "$input" \
    | /usr/bin/sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" \
    | head -n1
}

event="$(extract hook_event_name)"
session="$(extract session_id)"

session="$(printf '%s' "$session" | tr -cd 'A-Za-z0-9._-')"
[ -z "$session" ] && session="default"

mkdir -p "$LEASE_DIR"
lease_file="${LEASE_DIR}/${session}"

case "$event" in
  Stop|StopFailure|SessionEnd)
    rm -f "$lease_file"
    ;;
  *)
    printf '%s' "$(( $(date +%s) + BUSY_TTL ))" > "$lease_file"
    ;;
esac

exit 0
