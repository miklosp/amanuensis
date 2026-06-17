---
name: xcode-build
description: Use when running xcodebuild on this project (build, test, archive, analyze, -list) or querying unified logs (log show / log stream) for the running app. /usr/bin/xcodebuild and /usr/bin/log both self-refuse inside the sandbox with "Cannot run while sandboxed"; this skill routes both through an outside-sandbox Hammerspoon daemon via $XDG_STATE_HOME/xcode-build/. Also use when interpreting build/test results, parsing .xcresult bundles, or auditing past daemon actions.
---

# xcode-build

You run inside a seatbelt sandbox that cannot execute `/usr/bin/xcodebuild` or
`/usr/bin/log` directly — both self-detect the sandbox and refuse with
"Cannot run while sandboxed". This skill is your verification channel: drop a
JSON request into an inbox, get back a streamed log + result JSON written by
a Hammerspoon daemon running outside the sandbox.

Two helpers live in `./scripts/`:

- `xcode-build-helper.sh` — submits `xcodebuild` jobs (default binary).
- `log-helper.sh`         — submits `log show` / `log stream` queries.

Both block until the daemon writes a result, print result JSON to stdout and
the log path to stderr, and exit 0 iff the underlying command exited 0.

## Submitting a build

```bash
./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -list
./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis build
./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis \
    -destination "platform=macOS" test
```

## Querying logs

```bash
./scripts/log-helper.sh show --last 5m --info \
    --predicate 'process == "Amanuensis"'
./scripts/log-helper.sh show --last 30s --style ndjson \
    --predicate 'subsystem == "work.miklos.amanuensis"'
```

The daemon kills any job after `MAX_DURATION_S` (default 600s), so `log stream`
always ends with `killed:"timeout"` — prefer `log show --last <N>` for snapshot
queries unless you genuinely want a live 10-minute capture.

## Raw protocol (if the helper isn't present)

```bash
JOB=$(uuidgen | tr 'A-Z' 'a-z')
Q=$HOME/.local/state/xcode-build
jq -n --arg cwd "$PWD" \
   '{cwd:$cwd, bin:"xcodebuild", args:["-project","...","-scheme","...","build"]}' \
  > "$Q/inbox/$JOB.json.tmp"
mv "$Q/inbox/$JOB.json.tmp" "$Q/inbox/$JOB.json"     # atomic — daemon ignores .tmp
until [ -f "$Q/outbox/$JOB.json" ]; do sleep 1; done  # wait for result sentinel
cat "$Q/outbox/$JOB.json"
cat "$Q/outbox/$JOB.log"
```

The `.tmp → rename` step is **required** — without it the FSEvent watcher
fires on a half-written file and the daemon records `bad-json`.

`bin` defaults to `"xcodebuild"` if omitted; set `"log"` for unified-logging
queries.

## What's allowed

The daemon rejects requests before invocation if anything below is violated;
the result is `{"exit":-1, "error":"..."}` and the audit log records it.

- **Binaries**: `xcodebuild` → `/usr/bin/xcodebuild`, `log` → `/usr/bin/log`.
  No other binaries can be selected.
- **xcodebuild flags allowlist**: `-workspace -project -scheme -destination
  -configuration -sdk -derivedDataPath -resultBundlePath -only-testing
  -skip-testing -testPlan -arch -quiet -json -list
  -parallel-testing-enabled -disable-concurrent-destination-testing`.
- **xcodebuild actions allowlist**: `build test clean archive analyze
  build-for-testing test-without-building`.
- **log flags allowlist**: `--predicate --last --start --end --style --type
  --process --info --debug --signpost --source --color`.
- **log subcommands allowlist**: `show stream`.
- **`KEY=VALUE` args**: rejected entirely. Used by `xcodebuild` to inject
  build settings (`OTHER_SWIFT_FLAGS=-Xfrontend -load-plugin-executable ...`
  is arbitrary code execution). If you think you need one, you don't — change
  the project, not the invocation. (`log` predicate values may contain `==`,
  but those are consumed as flag values and aren't subject to this check.)
- **Paths**: `-workspace`, `-project`, and `cwd` must canonicalize under one
  of the configured `PROJECT_ROOTS` in `~/.config/hammerspoon/build-daemon.lua`
  (symlinks and `../` are resolved first; relative paths resolve against
  `job.cwd`). `-derivedDataPath` and `-resultBundlePath` must canonicalize
  under `~/.cache/xcode-build/`.
- **Env**: fixed (`PATH`, `HOME`, `DEVELOPER_DIR`). You cannot inject env vars.

## Interpreting results

`outbox/<jobid>.json`:

```json
{
  "jobid": "...",
  "exit": 0,                  // underlying tool's exit; -1 means daemon rejected
  "durationMs": 12345,
  "log": "/Users/miklos/.local/state/xcode-build/outbox/<jobid>.log",
  "killed": null              // or "timeout" or "log-overflow"
}
```

- `exit == 0`: command succeeded.
- `exit > 0`: command failed; read `log` for details.
- `exit == -1`: daemon validation rejected the request; `error` field has why.
- `killed == "timeout"`: ran longer than `MAX_DURATION_S` (default 600s).
- `killed == "log-overflow"`: produced more than `MAX_LOG_BYTES` (default 50MB).

For structured test pass/fail, add `-resultBundlePath ~/.cache/xcode-build/<name>.xcresult`
and parse with `xcresulttool` (which runs fine inside the sandbox).

## Auditing your own actions

The daemon appends a JSON-Lines record to `~/.local/state/xcode-build/audit.log`
for every submission — including rejected ones — with timestamp, `bin`, args,
cwd, exit, duration, and kill reason. You have **read-only** access to this
file (sandbox-enforced), so it's a trustworthy record of what you actually ran.

```bash
./scripts/xcode-build-helper.sh --audit          # last 20 entries
./scripts/xcode-build-helper.sh --audit 100      # last 100
./scripts/xcode-build-helper.sh --tail           # follow the most recent log
```

## Operational notes

- **Single-flight queue**: one job at a time across both binaries; subsequent
  submissions queue in inbox order. If you have several independent things to
  verify, submit them all and poll for each result file.
- **Hammerspoon must be running**. If it isn't, the helper waits the full
  900s timeout then exits 124. To probe daemon liveness cheaply, submit
  `xcodebuild -list` against the project — completes in ~1s if up.
- **Project files are not validated**. The daemon protects against agent
  *confusion* (wrong path, malformed args), not malicious intent — Run Script
  build phases inside `.xcodeproj` still execute with full privileges. If
  you're modifying `project.pbxproj`, `*.xcconfig`, `Package.swift`, or
  `Package.resolved`, treat that as a privileged edit and surface it to the
  user before submitting a build.
- **First-time-in-project**: if the helper reports `"error":"...path not
  under PROJECT_ROOTS..."`, this project's directory isn't in the daemon's
  allowlist. Tell the user; they need to add it to
  `~/.config/hammerspoon/build-daemon.lua` and reload Hammerspoon.

## Paths

| Path | Role | Your access |
|---|---|---|
| `~/.local/state/xcode-build/inbox/`       | submit jobs here              | **rw** |
| `~/.local/state/xcode-build/outbox/`      | logs + result JSON            | r      |
| `~/.local/state/xcode-build/audit.log`    | append-only audit trail       | r      |
| `~/.cache/xcode-build/`                   | DerivedData, .xcresult        | r      |
| `~/.config/hammerspoon/build-daemon.lua`  | daemon source                 | none   |
| `./build-daemon.lua`                      | repo copy (kept in sync)      | r+w    |
| `./scripts/xcode-build-helper.sh`         | xcodebuild submitter          | r+x    |
| `./scripts/log-helper.sh`                 | log submitter                 | r+x    |
