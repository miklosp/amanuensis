#!/usr/bin/env bash
# Fetch one FLEURS test clip + reference transcript for each of the 7 Indic
# languages IndicConformer-600M supports, into the gated-integration-test
# Fixtures dir. Run this OUTSIDE the Claude Code sandbox (needs network + a
# writable HF cache). Requires `uv`. Uses your existing `huggingface-cli login`
# / HF_TOKEN if present — authenticated requests get higher rate limits and are
# much faster (FLEURS ships one chunky parquet shard per language).
#
# Usage:
#   ./scripts/fetch-fleurs-indic-samples.sh           # all 7 languages
#   ./scripts/fetch-fleurs-indic-samples.sh hi bn     # just these
# Languages whose fixture already exists are skipped, so a re-run resumes.
set -euo pipefail
export DEST="$(dirname "$0")/../Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures"
# Give each HF request more headroom (unauthenticated pulls can be slow).
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-120}"
# NB: intentionally do NOT override HF_HOME — the default (~/.cache/huggingface)
# is where `huggingface-cli login` stores your token; overriding it would hide
# your login and force unauthenticated, rate-limited downloads.
export LANGS="${*:-hi bn mr te ta ml kn}"
mkdir -p "$DEST"
uv run --with datasets --with soundfile - <<'PY'
import os, soundfile as sf
from datasets import load_dataset

out = os.environ["DEST"]
config_for = {
    "hi": "hi_in", "bn": "bn_in", "mr": "mr_in", "te": "te_in",
    "ta": "ta_in", "ml": "ml_in", "kn": "kn_in",
}
for code in os.environ["LANGS"].split():
    config = config_for.get(code)
    if config is None:
        print(f"{code}: unknown language, skipping")
        continue
    wav = os.path.join(out, f"fleurs_{code}.wav")
    if os.path.exists(wav):
        print(f"{code}: already present, skipping")
        continue
    ds = load_dataset("google/fleurs", config, split="test", streaming=True)
    row = next(iter(ds))
    sf.write(wav, row["audio"]["array"], row["audio"]["sampling_rate"])
    with open(os.path.join(out, f"fleurs_{code}.txt"), "w") as f:
        f.write(row["transcription"])
    print(f"{code}: {row['transcription'][:60]}")
PY
