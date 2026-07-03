#!/usr/bin/env bash
set -euo pipefail
export DEST="$(dirname "$0")/../Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures"
mkdir -p "$DEST"
uv run --with datasets --with soundfile - <<'PY'
import os, soundfile as sf
from datasets import load_dataset
ds = load_dataset("google/fleurs", "hi_in", split="test", streaming=True)
row = next(iter(ds))
out = os.environ["DEST"]
sf.write(os.path.join(out, "fleurs_hi.wav"), row["audio"]["array"], row["audio"]["sampling_rate"])
open(os.path.join(out, "fleurs_hi.txt"), "w").write(row["transcription"])
print("wrote", row["transcription"][:60])
PY
