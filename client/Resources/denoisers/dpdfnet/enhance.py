"""Noise removal helper (koom client and audio lab): DPDFNet.

    enhance.py <input.wav> <output.wav> [--model NAME]
    enhance.py --prefetch [--model NAME]

Input is mono 48 kHz WAV. Output is float32 WAV at 48 kHz with the
input's exact length. Prints one JSON line with timings. --prefetch only
downloads and loads the model, so later runs work offline.
"""

import argparse
import json
import time

import numpy as np
import soundfile as sf

started = time.perf_counter()
import dpdfnet  # noqa: E402  (import time counts as model load)

parser = argparse.ArgumentParser()
parser.add_argument("input", nargs="?")
parser.add_argument("output", nargs="?")
parser.add_argument("--model", default="dpdfnet8_48khz_hr")
parser.add_argument("--prefetch", action="store_true")
args = parser.parse_args()
if args.prefetch:
    dpdfnet.enhance(
        np.zeros(24_000, dtype=np.float32), sample_rate=48_000, model=args.model
    )
    print(json.dumps({"load_seconds": round(time.perf_counter() - started, 3)}))
    raise SystemExit(0)
if not (args.input and args.output):
    parser.error("input and output are required unless --prefetch is given")

audio, rate = sf.read(args.input, dtype="float32")
if audio.ndim > 1:
    audio = audio.mean(axis=1)

# Warm up on a short slice so model download/load isn't counted as
# processing time.
dpdfnet.enhance(audio[: rate // 2], sample_rate=rate, model=args.model)
loaded = time.perf_counter()

enhanced = np.asarray(
    dpdfnet.enhance(audio, sample_rate=rate, model=args.model), dtype=np.float32
).reshape(-1)
processed = time.perf_counter()

enhanced = np.pad(enhanced, (0, max(0, len(audio) - len(enhanced))))[: len(audio)]
sf.write(args.output, enhanced, rate, subtype="FLOAT")
print(
    json.dumps(
        {
            "load_seconds": round(loaded - started, 3),
            "process_seconds": round(processed - loaded, 3),
        }
    )
)
