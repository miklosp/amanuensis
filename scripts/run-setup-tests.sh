#!/usr/bin/env bash
# Installs the xcodeproj gem (once, into /tmp) and runs setup-tests.rb.
# Run from the repo root.
set -euo pipefail

GEM_DIR=/tmp/audio-pipeline-gems

if ! GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby -e 'require "xcodeproj"' 2>/dev/null; then
  echo "installing xcodeproj into $GEM_DIR …"
  # If this fails citing the Ruby version, append a pin, e.g. -v 1.25.0
  gem install --install-dir "$GEM_DIR" --no-document xcodeproj
fi

GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby scripts/setup-tests.rb
