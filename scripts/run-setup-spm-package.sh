#!/usr/bin/env bash
# Wrapper for scripts/setup-spm-package.rb that ensures the xcodeproj gem is
# available. Run from the repo root with the product name as an argument:
#
#   scripts/run-setup-spm-package.sh AppSettings
set -euo pipefail

GEM_DIR=/tmp/audio-pipeline-gems

if ! GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby -e 'require "xcodeproj"' 2>/dev/null; then
  echo "installing xcodeproj into $GEM_DIR …"
  GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" gem install --install-dir "$GEM_DIR" --no-document xcodeproj
fi

GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby scripts/setup-spm-package.rb "$@"
