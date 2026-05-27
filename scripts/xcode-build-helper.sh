#!/usr/bin/env bash
# Project-local agent helper for the Hammerspoon xcode-build daemon.
# Drop into ./scripts/ of any Swift project alongside the xcode-build skill.
#
# Usage:
#   ./scripts/xcode-build-helper.sh -workspace Foo.xcworkspace -scheme Foo build
#   ./scripts/xcode-build-helper.sh -project  Bar.xcodeproj  -scheme Bar test
#   ./scripts/xcode-build-helper.sh --tail
#   ./scripts/xcode-build-helper.sh --audit [N]
#   ./scripts/xcode-build-helper.sh --help
#
# Exit code: 0 if xcodebuild succeeded, non-zero otherwise.
# Stdout: result JSON from the daemon.
# Stderr: log path.

set -euo pipefail

Q="${XDG_STATE_HOME:-$HOME/.local/state}/xcode-build"

usage() {
  cat <<'EOF'
Submit an xcodebuild job to the outside-sandbox Hammerspoon daemon.

Usage:
  xcode-build-helper.sh [xcodebuild args]   submit a build, block until result
  xcode-build-helper.sh --tail              tail the most recent build log
  xcode-build-helper.sh --audit [N]         show last N audit entries (default 20)
  xcode-build-helper.sh --help              this message

Examples:
  xcode-build-helper.sh -workspace Foo.xcworkspace -scheme Foo -list
  xcode-build-helper.sh -workspace Foo.xcworkspace -scheme Foo build
  xcode-build-helper.sh -workspace Foo.xcworkspace -scheme Foo \
      -destination "platform=iOS Simulator,name=iPhone 16" test
EOF
}

case "${1:-}" in
  --help|-h)
    usage; exit 0
    ;;
  --tail)
    latest=$(ls -t "$Q"/outbox/*.log 2>/dev/null | head -1) || true
    [ -n "${latest:-}" ] || { echo "no build logs yet at $Q/outbox/" >&2; exit 1; }
    echo "tailing: $latest" >&2
    exec tail -F "$latest"
    ;;
  --audit)
    n="${2:-20}"
    [ -f "$Q/audit.log" ] || { echo "no audit log at $Q/audit.log" >&2; exit 1; }
    tail -n "$n" "$Q/audit.log" | jq -c .
    exit 0
    ;;
  "")
    usage >&2; exit 2
    ;;
esac

# Default: submit a build and wait for the result sentinel.
[ -d "$Q/inbox" ] || { echo "daemon inbox missing ($Q/inbox); is Hammerspoon running?" >&2; exit 1; }

job=$(uuidgen | tr 'A-Z' 'a-z')
# jq 1.8 parses flag-like values after --args (e.g. -project) as jq options,
# so build the args array element-by-element instead.
args_json='[]'
for a in "$@"; do
  args_json=$(jq -nc --argjson cur "$args_json" --arg a "$a" '$cur + [$a]')
done
payload=$(jq -nc --arg cwd "$PWD" --argjson args "$args_json" '{cwd:$cwd, args:$args}')
printf '%s' "$payload" > "$Q/inbox/$job.json.tmp"
mv "$Q/inbox/$job.json.tmp" "$Q/inbox/$job.json"

timeout=900
elapsed=0
until [ -f "$Q/outbox/$job.json" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "xcode-build: timeout waiting for $job (is the daemon running?)" >&2
    exit 124
  fi
done

result=$(cat "$Q/outbox/$job.json")
printf '%s\n' "$result"
printf 'log: %s\n' "$Q/outbox/$job.log" >&2
printf '%s' "$result" | jq -e '.exit == 0' >/dev/null
