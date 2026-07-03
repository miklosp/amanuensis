#!/usr/bin/env bash
# Fetch one FLEURS test clip + reference transcript for each of the 7 Indic
# languages IndicConformer-600M supports, into the gated-integration-test
# Fixtures dir. Run this OUTSIDE the Claude Code sandbox (it needs a writable
# Hugging Face cache and network). Requires `uv`.
set -euo pipefail
export DEST="$(dirname "$0")/../Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures"
# Keep the HF cache in a writable location so a token/cache lookup can't fail.
export HF_HOME="${HF_HOME:-${TMPDIR:-/tmp}/amanuensis-hf-cache}"
mkdir -p "$DEST" "$HF_HOME"
uv run --with datasets --with soundfile - <<'PY'
import os, soundfile as sf
from datasets import load_dataset

out = os.environ["DEST"]
# FLEURS config -> language code used by the engine.
configs = {
    "hi_in": "hi", "bn_in": "bn", "mr_in": "mr", "te_in": "te",
    "ta_in": "ta", "ml_in": "ml", "kn_in": "kn",
}
for config, code in configs.items():
    ds = load_dataset("google/fleurs", config, split="test", streaming=True)
    row = next(iter(ds))
    sf.write(os.path.join(out, f"fleurs_{code}.wav"),
             row["audio"]["array"], row["audio"]["sampling_rate"])
    with open(os.path.join(out, f"fleurs_{code}.txt"), "w") as f:
        f.write(row["transcription"])
    print(f"{code}: {row['transcription'][:60]}")
PY
