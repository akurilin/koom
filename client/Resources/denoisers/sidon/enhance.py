"""Noise removal helper (koom client and audio lab): Sidon v0.1 speech
restoration.

    enhance.py <input.wav> <output.wav>
    enhance.py --prefetch

Sidon is generative: it predicts clean w2v-BERT 2.0 features from 16 kHz
input and resynthesizes 48 kHz speech with a vocoder, so the output is a
new waveform rather than a filtered copy. This follows the authors'
reference inference (Hugging Face space sarulab-speech/sidon_demo_beta),
using the CPU TorchScript checkpoints.

It stays on the CPU: the published checkpoints are traced TorchScript
with CPU tensor creation baked in, so moving them to the Mac GPU (MPS)
fails with mixed-device errors, and the untraced weights aren't released.
CPU runs at roughly 3x real time on an M2 Max.

Input is mono 48 kHz WAV. Output is float32 WAV at 48 kHz with the
input's exact length. Prints one JSON line with timings. --prefetch only
downloads and loads the model, so later runs work offline. Weights are
pinned to the Hugging Face revisions rated in the audio lab.
"""

import argparse
import json
import time

import numpy as np
import soundfile as sf
import torch
import torchaudio
import transformers
from huggingface_hub import hf_hub_download

SIDON_REVISION = "b3b02d8bbd55fdbc410e6e46e76ef95ace4fbf52"
W2V_BERT_REVISION = "da985ba0987f70aaeb84a80f2851cfac8c697a7b"

parser = argparse.ArgumentParser()
parser.add_argument("input", nargs="?")
parser.add_argument("output", nargs="?")
parser.add_argument("--prefetch", action="store_true")
args = parser.parse_args()
if not args.prefetch and not (args.input and args.output):
    parser.error("input and output are required unless --prefetch is given")

started = time.perf_counter()
fe = torch.jit.load(
    hf_hub_download(
        "sarulab-speech/sidon-v0.1",
        "feature_extractor_cpu.pt",
        revision=SIDON_REVISION,
    ),
    map_location="cpu",
)
decoder = torch.jit.load(
    hf_hub_download(
        "sarulab-speech/sidon-v0.1", "decoder_cpu.pt", revision=SIDON_REVISION
    ),
    map_location="cpu",
)
preprocessor = transformers.SeamlessM4TFeatureExtractor.from_pretrained(
    "facebook/w2v-bert-2.0", revision=W2V_BERT_REVISION
)
loaded = time.perf_counter()
if args.prefetch:
    print(json.dumps({"load_seconds": round(loaded - started, 3)}))
    raise SystemExit(0)

audio, rate = sf.read(args.input, dtype="float32")
if audio.ndim > 1:
    audio = audio.mean(axis=1)
peak = float(np.abs(audio).max()) or 1.0

with torch.inference_mode():
    waveform = torch.from_numpy(0.9 * audio / peak).view(1, -1)
    waveform = torchaudio.functional.highpass_biquad(waveform, rate, 50)
    wav_16k = torchaudio.functional.resample(waveform, rate, 16_000)
    wav_16k = torch.nn.functional.pad(wav_16k, (0, 24_000))
    restored = []
    feature_cache = None
    for chunk in wav_16k.view(-1).split(16_000 * 96):
        inputs = preprocessor(
            torch.nn.functional.pad(chunk, (160, 160)),
            sampling_rate=16_000,
            return_tensors="pt",
        )
        feature = fe(inputs["input_features"])["last_hidden_state"]
        if feature_cache is not None:
            feature = torch.cat([feature_cache, feature], dim=1)
        restored.append(decoder(feature.transpose(1, 2)).view(-1)[:-960])
        feature_cache = feature[:, -1:]
    output = torch.cat(restored).numpy().astype(np.float32)
processed = time.perf_counter()

# The resynthesized output trails the input by ~7.5 ms (measured with
# loudness-envelope cross-correlation: 7-8 ms on every clip tried; raw
# waveform correlation is unreliable because the vocoder doesn't keep phase).
OUTPUT_DELAY_SAMPLES = 360
output = output[OUTPUT_DELAY_SAMPLES:]

target = int(len(audio) * 48_000 / rate)
output = np.pad(output, (0, max(0, target - len(output))))[:target]
sf.write(args.output, output, 48_000, subtype="FLOAT")
print(
    json.dumps(
        {
            "load_seconds": round(loaded - started, 3),
            "process_seconds": round(processed - loaded, 3),
        }
    )
)
