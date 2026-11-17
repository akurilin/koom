"""Noise removal helper (koom client and audio lab): ClearerVoice-Studio
MossFormer2_SE_48K.

    enhance.py <input.wav> <output.wav>
    enhance.py --prefetch

Input is mono 48 kHz WAV. Output is float32 WAV at 48 kHz with the
input's exact length. Prints one JSON line with timings. --prefetch only
downloads and loads the model, so later runs work offline.
"""

import argparse
import json
import os
import time

import numpy as np
import soundfile as sf

parser = argparse.ArgumentParser()
parser.add_argument("input", nargs="?")
parser.add_argument("output", nargs="?")
parser.add_argument("--prefetch", action="store_true")
args = parser.parse_args()
if not args.prefetch and not (args.input and args.output):
    parser.error("input and output are required unless --prefetch is given")

started = time.perf_counter()
from clearvoice import ClearVoice  # noqa: E402

# ClearVoice fetches checkpoints relative to the working directory, which
# the caller points at a cache folder.
model = ClearVoice(task="speech_enhancement", model_names=["MossFormer2_SE_48K"])
loaded = time.perf_counter()
if args.prefetch:
    print(json.dumps({"load_seconds": round(loaded - started, 3)}))
    raise SystemExit(0)
input_path = os.path.abspath(args.input)
output_path = os.path.abspath(args.output)

enhanced = model(input_path=input_path, online_write=False)
processed = time.perf_counter()

audio, rate = sf.read(input_path, dtype="float32")
enhanced = np.asarray(enhanced, dtype=np.float32).reshape(-1)
enhanced = np.pad(enhanced, (0, max(0, len(audio) - len(enhanced))))[: len(audio)]
sf.write(output_path, enhanced, rate, subtype="FLOAT")
print(
    json.dumps(
        {
            "load_seconds": round(loaded - started, 3),
            "process_seconds": round(processed - loaded, 3),
        }
    )
)
