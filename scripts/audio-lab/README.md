# Audio lab

A local listening page for choosing how koom should clean up and level
recorded audio. Each clip is rendered through several cleanup chains. The
page plays every version in sync, so you can switch mid-sentence, score
each one, and pick the best. When one chain keeps winning across real
scenarios, port it into `client/Sources/koom/LoudnessNormalizer.swift`.

```bash
npm run audio-lab:seed
```

```bash
npm run audio-lab
```

Then open http://127.0.0.1:5174. Drop audio or video files onto the page
(your own koom recordings work) to add clips. Clips and renders live in
`scripts/audio-lab/.data/` (gitignored): `npm run audio-lab:seed` rebuilds
the same starter clips from pinned public URLs, and renders are regenerated
on demand. Ratings are the one thing that can't be rebuilt, so they're
saved to `scripts/audio-lab/ratings.json`, which is tracked in git. Ratings
for clips you upload yourself are kept there too, but those clips aren't
in the repo.

## What gets compared

Chains are defined in `lab.ts`. Each one is a denoiser (or none) followed
by a leveler:

| Chain                  | Denoise                                                      | Level                                       |
| ---------------------- | ------------------------------------------------------------ | ------------------------------------------- |
| Original               | none                                                         | none (reference only, not rated)            |
| koom today             | none                                                         | koom's current fixed gain, capped by peaks  |
| Static gain + limiter  | none                                                         | full gain to -16 LUFS, limiter at -1.5 dBTP |
| Auto-leveler + limiter | none                                                         | `dynaudnorm` (~7.5 s window), then limiter  |
| Apple voice isolation  | `AUSoundIsolation` (built into macOS), HQ/standard/70% blend | limiter (one variant uses auto-leveler)     |
| RNNoise                | ffmpeg `arnndn` with the `bd` model                          | limiter                                     |
| FFT denoise            | ffmpeg `highpass` + `afftdn`                                 | limiter                                     |
| DPDFNet                | `dpdfnet8_48khz_hr` (Ceva, Apache-2.0), CPU via ONNX         | limiter                                     |
| ClearerVoice           | MossFormer2_SE_48K (Alibaba, Apache-2.0), Mac GPU via MPS    | limiter                                     |
| Sidon                  | generative restoration (MIT), CPU                            | limiter                                     |

All outputs except the original and "koom today" end at about -16 LUFS,
so loudness alone shouldn't pick the winner. Editing a chain in `lab.ts`
re-renders only that chain on the next start. Bump `PROCESSING_VERSION`
there to re-render everything after a change to `process.ts`.

Chains marked `retired: true` in `lab.ts` clearly lost in listening tests
(koom today, static gain + limiter, auto-leveler + limiter, the 70% Apple
blend, RNNoise, FFT). The UI hides them unless "Show retired" is on; they
still render and keep their ratings.

## Python model helpers

DPDFNet, ClearerVoice and Sidon run as separate helper processes:
`client/Resources/denoisers/<helper>/enhance.py`, each in its own pinned uv
environment (the `uv.lock` next to it) under `.data/envs/`. The koom client
installs the same helpers for its noise removal setting, so the lab always
tests exactly what ships. Install them once (needs `uv`; about 1.7 GB of
environments, plus about 1.5 GB of model weights on first render):

```bash
npm run audio-lab:models
```

The lab skips any helper that isn't installed. Each variant shows its
denoiser's speed relative to the clip's length (model loading excluded),
and Summary shows the median across clips.

GPU use: ClearerVoice picks the Mac GPU (Metal/MPS) on its own. Sidon's
published checkpoints are CPU-traced TorchScript and can't be moved to MPS,
so it runs on the CPU. DPDFNet's package uses ONNX Runtime on the CPU, and
its streaming frame-by-frame design gains little from a GPU.

## Starter clips

`seed.ts` fetches only the files it needs (~70 MB, using HTTP range
requests into the dataset zips):

- `real-*`: real laptop-mic, webcam and headset recordings in cafés, open
  offices, kitchens and hallways, with typing, chewing, copiers, AC hum,
  door slams and dishes, from the
  [Microsoft DNS Challenge](https://github.com/microsoft/DNS-Challenge)
  real-recordings test set. These are 16 kHz, so they sound dull even
  unprocessed.
- `synth-*`: 48 kHz studio speech from
  [EARS](https://github.com/facebookresearch/ears_dataset) (CC BY-NC 4.0)
  mixed with real noise from [DEMAND](https://zenodo.org/records/1227121)
  (CC BY 4.0) or a synthesized fan. Also two constructed loudness cases:
  a call with big dynamics (whisper → yelling), and a too-quiet mic with
  desk knocks that block koom's current fixed-gain boost.

These clips are for local listening only. Don't commit or redistribute
them.

## Notes

- `isolate.swift` is compiled on first start (`swiftc`). The unit reports
  zero latency but actually delays its output (4440 frames on the HQ
  model), so the tool measures that delay with an impulse and trims it.
  This is worth knowing when porting it into the app.
- ffmpeg's `arnndn` and `afftdn` add fixed delays (480 and 1199 samples at
  48 kHz). `process.ts` trims them so every variant stays in sync.
