#!/usr/bin/env bash
# Project-local agent helper for the Hammerspoon log channel.
# Routes `log show` / `log stream` through the same outbox queue as builds.
#
# Usage:
#   ./scripts/log-helper.sh show --last 5m --info --predicate 'process == "audio-pipeline"'
#   ./scripts/log-helper.sh stream --info --predicate 'process == "audio-pipeline"'
#   ./scripts/log-helper.sh --help
#
# Allowed subcommands: show, stream.
# Allowed flags (with value): --predicate --last --start --end --style --type --process
# Allowed flags (no value):  --info --debug --signpost --source --color
# Anything else is rejected by the daemon before invocation.
#
# Daemon kills any job after 10 minutes, so `log stream` will hit
# killed:"timeout" — agents typically want `log show --last <N>` instead.

set -euo pipefail

Q="${XDG_STATE_HOME:-$HOME/.local/state}/xcode-build"

usage() {
  cat <<'EOF'
Submit a `log` job to the Hammerspoon daemon.

Usage:
  log-helper.sh show   [flags] [--predicate 'NSPredicate string']
  log-helper.sh stream [flags] [--predicate 'NSPredicate string']
  log-helper.sh --help

Examples:
  log-helper.sh show --last 5m --info \
      --predicate 'process == "audio-pipeline"'
  log-helper.sh show --last 30s --style ndjson \
      --predicate 'subsystem == "work.miklos.audio-pipeline"'
EOF
}

case "${1:-}" in
  --help|-h)
    usage; exit 0
    ;;
  "")
    usage >&2; exit 2
    ;;
esac

[ -d "$Q/inbox" ] || { echo "daemon inbox missing ($Q/inbox); is Hammerspoon running?" >&2; exit 1; }

job=$(uuidgen | tr 'A-Z' 'a-z')
args_json='[]'
for a in "$@"; do
  args_json=$(jq -nc --argjson cur "$args_json" --arg a "$a" '$cur + [$a]')
done
payload=$(jq -nc --arg cwd "$PWD" --argjson args "$args_json" \
            '{cwd:$cwd, bin:"log", args:$args}')
printf '%s' "$payload" > "$Q/inbox/$job.json.tmp"
mv "$Q/inbox/$job.json.tmp" "$Q/inbox/$job.json"

timeout=900
elapsed=0
until [ -f "$Q/outbox/$job.json" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "log-helper: timeout waiting for $job (is the daemon running?)" >&2
    exit 124
  fi
done

result=$(cat "$Q/outbox/$job.json")
printf '%s\n' "$result"
printf 'log: %s\n' "$Q/outbox/$job.log" >&2
printf '%s' "$result" | jq -e '.exit == 0' >/dev/null
