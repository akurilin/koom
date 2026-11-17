#!/usr/bin/env tsx
/*
 * Seeds the audio lab with noisy-speech clips from public datasets, so
 * there is something to listen to before anyone uploads their own.
 *
 *   npm run audio-lab:seed
 *
 * Two kinds of clips:
 *
 * - "real-*": real recordings of people talking on laptop mics, webcams
 *   and headsets in noisy places, from the Microsoft DNS Challenge
 *   (Interspeech 2020) real-recordings test set. 16 kHz, so they sound
 *   band-limited even before processing; each clip strings together a
 *   few takes from one scenario.
 * - "synth-*": 48 kHz studio speech from Meta's EARS dataset mixed with
 *   real 48 kHz noise beds from DEMAND (or a synthesized fan) at a known
 *   SNR, plus constructed loudness-dynamics cases.
 *
 * Datasets are read with HTTP range requests (see remote-zip.ts), so only
 * the few files used are downloaded (~70 MB in total). Existing clips are
 * skipped; delete a clip's directory to rebuild it. Also fetches the
 * RNNoise speech model that ffmpeg's arnndn filter needs.
 */

import { existsSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import { CACHE_DIR, CLIPS_DIR, RNNOISE_MODEL } from "./lab";
import { ffmpeg, measureLoudness, type ClipMeta } from "./process";
import {
  listRemoteZip,
  readRemoteZipEntry,
  type RemoteZipEntry,
} from "./remote-zip";

const USER_AGENT = "koom-audio-lab/1.0";
const DOWNLOADS = path.join(CACHE_DIR, "downloads");

const DNS_BASE =
  "https://media.githubusercontent.com/media/microsoft/DNS-Challenge/interspeech2020/master/datasets/test_set/real_recordings";
const DNS_SOURCE =
  "Microsoft DNS Challenge, Interspeech 2020 real-recordings test set (github.com/microsoft/DNS-Challenge)";
const EARS_URL = (speaker: string) =>
  `https://github.com/facebookresearch/ears_dataset/releases/download/dataset/${speaker}.zip`;
const DEMAND_URL = (environment: string) =>
  `https://zenodo.org/records/1227121/files/${environment}_48k.zip?download=1`;
const RNNOISE_MODEL_URL =
  "https://raw.githubusercontent.com/richardpl/arnndn-models/master/bd.rnnn";

// ---------------------------------------------------------------------------
// Downloads (cached)

async function download(url: string, destination: string): Promise<string> {
  if (existsSync(destination)) return destination;
  await mkdir(path.dirname(destination), { recursive: true });
  const response = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
  if (!response.ok) throw new Error(`GET ${url} -> HTTP ${response.status}`);
  const partial = `${destination}.partial`;
  await writeFile(partial, Buffer.from(await response.arrayBuffer()));
  await rename(partial, destination);
  return destination;
}

function dnsFile(name: string): Promise<string> {
  return download(`${DNS_BASE}/${name}`, path.join(DOWNLOADS, "dns", name));
}

const zipListings = new Map<string, Promise<RemoteZipEntry[]>>();

async function zipFile(url: string, entryName: string, destination: string) {
  if (existsSync(destination)) return destination;
  if (!zipListings.has(url)) zipListings.set(url, listRemoteZip(url));
  const entries = await zipListings.get(url)!;
  const entry = entries.find((candidate) => candidate.name === entryName);
  if (!entry) throw new Error(`${entryName} not found in ${url}`);
  console.log(
    `  fetching ${entryName} (${(entry.compressedSize / 1e6).toFixed(1)} MB)`,
  );
  await mkdir(path.dirname(destination), { recursive: true });
  const partial = `${destination}.partial`;
  await writeFile(partial, await readRemoteZipEntry(url, entry));
  await rename(partial, destination);
  return destination;
}

function earsFile(speaker: string, name: string): Promise<string> {
  return zipFile(
    EARS_URL(speaker),
    `${speaker}/${name}.wav`,
    path.join(DOWNLOADS, "ears", speaker, `${name}.wav`),
  );
}

/** DEMAND channel 1 of one environment (each zip holds 16 mics). */
function demandFile(environment: string): Promise<string> {
  return zipFile(
    DEMAND_URL(environment),
    `${environment}/ch01.wav`,
    path.join(DOWNLOADS, "demand", `${environment}.wav`),
  );
}

// ---------------------------------------------------------------------------
// Audio building blocks (all intermediate files mono 48 kHz float)

let tempCounter = 0;
function temp(): string {
  tempCounter += 1;
  return path.join(CACHE_DIR, "seed-tmp", `${process.pid}-${tempCounter}.wav`);
}

const MONO_48K = ["-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le"];

async function concat(inputs: string[], gapSeconds: number): Promise<string> {
  const output = temp();
  const args = inputs.flatMap((input) => ["-i", input]);
  const pads = inputs
    .map((_, index) => {
      const pad =
        index < inputs.length - 1 ? `,apad=pad_dur=${gapSeconds}` : "";
      return `[${index}]aresample=48000,aformat=channel_layouts=mono${pad}[a${index}]`;
    })
    .join(";");
  const joined = inputs.map((_, index) => `[a${index}]`).join("");
  await ffmpeg([
    "-loglevel",
    "error",
    ...args,
    "-filter_complex",
    `${pads};${joined}concat=n=${inputs.length}:v=0:a=1[out]`,
    "-map",
    "[out]",
    ...MONO_48K,
    output,
  ]);
  return output;
}

/** Scales a file so its integrated loudness lands on `lufs`. */
async function setLoudness(input: string, lufs: number): Promise<string> {
  const { integrated } = await measureLoudness(input);
  const output = temp();
  await ffmpeg([
    "-loglevel",
    "error",
    "-i",
    input,
    "-af",
    `volume=${(lufs - integrated).toFixed(2)}dB`,
    ...MONO_48K,
    output,
  ]);
  return output;
}

/** Mixes a noise bed under speech so speech is `snrDB` louder (in LUFS). */
async function mixNoise(
  speech: string,
  noise: string,
  snrDB: number,
  noiseStartSeconds = 0,
): Promise<string> {
  const speechLoudness = await measureLoudness(speech);
  const noiseLoudness = await measureLoudness(noise);
  const noiseGain =
    speechLoudness.integrated - snrDB - noiseLoudness.integrated;
  const output = temp();
  await ffmpeg([
    "-loglevel",
    "error",
    "-i",
    speech,
    "-stream_loop",
    "-1",
    "-ss",
    String(noiseStartSeconds),
    "-i",
    noise,
    "-filter_complex",
    `[0]aresample=48000,apad=pad_dur=0.5[s];[1]aresample=48000,aformat=channel_layouts=mono,volume=${noiseGain.toFixed(2)}dB,afade=t=in:d=0.3[n];[s][n]amix=inputs=2:duration=first:normalize=0[out]`,
    "-map",
    "[out]",
    ...MONO_48K,
    output,
  ]);
  return output;
}

/** A box fan / HVAC stand-in: shaped pink+brown noise with mains hum. */
async function synthFan(seconds: number): Promise<string> {
  const output = temp();
  await ffmpeg([
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    `anoisesrc=color=pink:amplitude=0.3:duration=${seconds}:seed=7`,
    "-f",
    "lavfi",
    "-i",
    `anoisesrc=color=brown:amplitude=0.5:duration=${seconds}:seed=11`,
    "-f",
    "lavfi",
    "-i",
    `aevalsrc=0.02*sin(2*PI*120*t)+0.01*sin(2*PI*240*t)+0.006*sin(2*PI*360*t):s=48000:d=${seconds}`,
    "-filter_complex",
    "[0]highpass=f=150,lowpass=f=3500,tremolo=f=0.4:d=0.08[p];[1]lowpass=f=400[b];[p][b][2]amix=inputs=3:normalize=0[out]",
    "-map",
    "[out]",
    ...MONO_48K,
    output,
  ]);
  return output;
}

/** Desk knocks and a mug set down, near full scale, at the given times. */
async function synthKnocks(seconds: number, times: number[]): Promise<string> {
  // max(0, t - start) keeps exp() finite before each onset; gte() gates
  // it to zero there (exp(+large) * 0 would be NaN).
  const burst = (amplitude: number, decay: number, hz: number, start: number) =>
    `${amplitude}*exp(-${decay}*max(0,t-${start}))*sin(2*PI*${hz}*(t-${start}))*gte(t,${start})`;
  const terms = times.flatMap((time) => [
    burst(0.75, 35, 85, time),
    burst(0.3, 250, 2300, time + 0.004),
  ]);
  const output = temp();
  await ffmpeg([
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    `aevalsrc='${terms.join("+")}':s=48000:d=${seconds}`,
    ...MONO_48K,
    output,
  ]);
  return output;
}

async function overlay(base: string, layer: string): Promise<string> {
  const output = temp();
  await ffmpeg([
    "-loglevel",
    "error",
    "-i",
    base,
    "-i",
    layer,
    "-filter_complex",
    "[0][1]amix=inputs=2:duration=first:normalize=0[out]",
    "-map",
    "[out]",
    ...MONO_48K,
    output,
  ]);
  return output;
}

async function durationOf(file: string): Promise<number> {
  const { stderr } = await ffmpeg(["-i", file, "-f", "null", "-"]);
  const match = [...stderr.matchAll(/time=(\d+):(\d+):([\d.]+)/g)].pop();
  if (!match) throw new Error(`could not read duration of ${file}`);
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

// ---------------------------------------------------------------------------
// Clip definitions

interface Seed {
  id: string;
  title: string;
  description: string;
  source: string;
  build: () => Promise<string>;
}

function dnsSeed(
  id: string,
  title: string,
  description: string,
  files: string[],
): Seed {
  return {
    id,
    title,
    description,
    source: DNS_SOURCE,
    build: async () => concat(await Promise.all(files.map(dnsFile)), 0.4),
  };
}

const takes = (pattern: string, values: (string | number)[]) =>
  values.map((value) => pattern.replace("#", String(value)));

const SEEDS: Seed[] = [
  dnsSeed(
    "real-cafe-laptop",
    "Café, laptop mic",
    "Real café recording on a Surface laptop's built-in mic.",
    takes("ms_realrec_speakerphone_spk1_cafe_S1#_surface.wav", [0, 1, 2]),
  ),
  dnsSeed(
    "real-cafe-laptop-2",
    "Café, laptop mic (second speaker)",
    "Another café, another speaker, Surface Book mic.",
    takes("ms_realrec_speakerphone_Senja_cafee_-0#_SurfaceBook.wav", [1, 2, 3]),
  ),
  dnsSeed(
    "real-cafeteria-headset",
    "Cafeteria, headset mic",
    "Busy cafeteria with a headset mic close to the mouth.",
    takes("ms_realrec_headset_Headphone-cafeteria-spk3-#.wav", [1, 2, 3]),
  ),
  dnsSeed(
    "real-typing-laptop",
    "Typing on the same laptop",
    "Speaker typing on the laptop whose mic is recording: the screen-recording worst case.",
    takes(
      "ms_realrec_speakerphone_Ashkan_Typing_S1#_SurfaceBook.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-typing-headset",
    "Typing, headset mic",
    "Keyboard clatter picked up by a headset.",
    takes("ms_realrec_headset_ergoe_Typing_s1#_T470s.wav", [0, 1, 2]),
  ),
  dnsSeed(
    "real-munching-laptop",
    "Eating chips, laptop mic",
    "Mouth and bag noises close to the mic.",
    takes(
      "ms_realrec_speakerphone_Jamie_Munching_S1#_SurfaceBook.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-copy-machine",
    "Copy machine, laptop mic",
    "Steady mechanical noise from a copier nearby.",
    takes(
      "ms_realrec_speakerphone_Puneet_CopyMachine_s1#_surface.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-open-office-webcam",
    "Open office, webcam mic",
    "Background chatter in an open office, picked up by a webcam.",
    takes(
      "ms_realrec_speakerphone_ergoe_OpenOffice_s1#_MSCinemaWebcam.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-hallway-laptop",
    "Echoey hallway, laptop mic",
    "Reverberant hallway: tests how denoisers treat room echo.",
    takes(
      "ms_realrec_speakerphone_Ashkan_B31Hallway-S1#_SurfaceBook.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-kitchen-laptop",
    "Office kitchen, laptop mic",
    "Kitchen noise: dishes, appliances, people.",
    takes(
      "ms_realrec_speakerphone_Ebrahim_B31Kitchen_S1#_SurfaceBook.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-clean-laptop",
    "Quiet room, laptop mic (control)",
    "Little background noise. Processing should not make this worse.",
    takes(
      "ms_realrec_speakerphone_Ashkan_Clean_S1#_SurfaceBook.wav",
      [0, 1, 2],
    ),
  ),
  dnsSeed(
    "real-air-conditioner",
    "Air conditioner / fan hum",
    "Three unrelated real recordings with AC or fan noise (AudioSet), back to back, so levels also jump between them.",
    [
      "audioset_realrec_airconditioner_2TE3LoA2OUQ.wav",
      "audioset_realrec_airconditioner_41GGhakrjoQ.wav",
      "audioset_realrec_airconditioner_7EYjHph6ZgM.wav",
    ],
  ),
  dnsSeed(
    "real-door-slams",
    "Doors banging",
    "Loud door transients over speech (AudioSet): tests limiters and transient handling.",
    [
      "audioset_realrec_door_-7eCzlHCVFc.wav",
      "audioset_realrec_door_0aIsaxK2F_E.wav",
      "audioset_realrec_door_1fysi-6uc9w.wav",
    ],
  ),
  dnsSeed(
    "real-dishes-clatter",
    "Dishes clattering",
    "Clattering dishes and cutlery over speech (AudioSet).",
    [
      "audioset_realrec_clatter_7KUIyRIW4gM.wav",
      "audioset_realrec_clatter_DQZyOwfY_s4.wav",
      "audioset_realrec_clatter_hTwI-gO0cQ4.wav",
    ],
  ),
  {
    id: "studio-clean-48k",
    title: "Studio recording, no noise (control)",
    description:
      "Professionally recorded 48 kHz speech in an anechoic studio, untouched apart from a level change to -22 LUFS, which puts its peaks just under -1 dBTP without clipping. Already excellent, so any audible change from processing is damage.",
    source: "Speech: EARS p003 (CC BY-NC 4.0).",
    build: async () =>
      setLoudness(
        await concat(
          [
            await earsFile("p003", "emo_neutral_freeform"),
            await earsFile("p003", "sentences_24_regular"),
          ],
          0.6,
        ),
        -22,
      ),
  },
  {
    id: "synth-cafeteria-48k",
    title: "Cafeteria, 48 kHz (mixed, SNR 5 dB)",
    description:
      "Full-bandwidth studio speech with a real cafeteria recording mixed in loud. Speech is only 5 LU above the noise.",
    source:
      "Speech: EARS p001 (CC BY-NC 4.0). Noise: DEMAND PCAFETER (CC BY 4.0).",
    build: async () =>
      mixNoise(
        await concat(
          [
            await earsFile("p001", "rainbow_03_regular"),
            await earsFile("p001", "sentences_16_regular"),
          ],
          0.6,
        ),
        await demandFile("PCAFETER"),
        5,
        40,
      ),
  },
  {
    id: "synth-street-cafe-48k",
    title: "Street café terrace, 48 kHz (mixed, SNR 8 dB)",
    description:
      "Outdoor café: traffic, voices, cutlery. Different speaker from the other mixes.",
    source:
      "Speech: EARS p002 (CC BY-NC 4.0). Noise: DEMAND SCAFE (CC BY 4.0).",
    build: async () =>
      mixNoise(
        await concat(
          [
            await earsFile("p002", "rainbow_03_regular"),
            await earsFile("p002", "sentences_16_regular"),
          ],
          0.6,
        ),
        await demandFile("SCAFE"),
        8,
        90,
      ),
  },
  {
    id: "synth-fan-48k",
    title: "Desk fan / HVAC, 48 kHz (mixed, SNR 12 dB)",
    description:
      "Studio speech over a synthesized fan: shaped broadband noise with 120 Hz mains hum and a slow wobble.",
    source: "Speech: EARS p001 (CC BY-NC 4.0). Fan: synthesized with ffmpeg.",
    build: async () => {
      const speech = await concat(
        [
          await earsFile("p001", "sentences_24_regular"),
          await earsFile("p001", "rainbow_06_regular"),
        ],
        0.6,
      );
      return mixNoise(speech, await synthFan(60), 12);
    },
  },
  {
    id: "synth-call-dynamics-48k",
    title: "Call with big dynamics, 48 kHz",
    description:
      "One speaker, normal → whisper → leaned away from the mic → laughing → loud → yelling → normal, over a quiet office. Tests leveling: the quiet parts should come up and the loud parts down.",
    source:
      "Speech: EARS p001 (CC BY-NC 4.0). Room: DEMAND OOFFICE (CC BY 4.0).",
    build: async () => {
      const segments: [string, number][] = [
        ["sentences_01_regular", -30],
        ["rainbow_02_whisper", -46],
        ["sentences_16_regular", -42],
        ["nonverbal_laughter_open", -24],
        ["sentences_01_loud", -21],
        ["nonverbal_yelling", -17],
        ["sentences_24_regular", -30],
      ];
      const leveled = [];
      for (const [name, lufs] of segments) {
        leveled.push(await setLoudness(await earsFile("p001", name), lufs));
      }
      const speech = await concat(leveled, 0.5);
      // Room tone sits 26 LU under the normal-speech level (-30 LUFS).
      // Levels keep the yelling's peaks just under full scale.
      const room = await setLoudness(await demandFile("OOFFICE"), -56);
      return overlay(speech, room);
    },
  },
  {
    id: "synth-quiet-with-knocks-48k",
    title: "Quiet mic with desk knocks, 48 kHz",
    description:
      "Speech recorded far too quietly (about -36 LUFS), with a few near-full-scale desk knocks. koom's static gain cannot boost this because the knocks use up the headroom.",
    source:
      "Speech: EARS p001 (CC BY-NC 4.0). Knocks: synthesized with ffmpeg.",
    build: async () => {
      const speech = await setLoudness(
        await concat(
          [
            await earsFile("p001", "sentences_19_regular"),
            await earsFile("p001", "rainbow_05_regular"),
          ],
          0.6,
        ),
        -36,
      );
      const seconds = await durationOf(speech);
      const knocks = await synthKnocks(seconds, [
        seconds * 0.18,
        seconds * 0.52,
        seconds * 0.81,
      ]);
      return overlay(speech, knocks);
    },
  },
];

// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  await mkdir(CLIPS_DIR, { recursive: true });

  if (!existsSync(RNNOISE_MODEL)) {
    console.log("Fetching RNNoise model (bd.rnnn) ...");
    await download(RNNOISE_MODEL_URL, RNNOISE_MODEL);
  }

  await mkdir(path.join(CACHE_DIR, "seed-tmp"), { recursive: true });

  let failures = 0;
  for (const seed of SEEDS) {
    const clipDir = path.join(CLIPS_DIR, seed.id);
    if (existsSync(path.join(clipDir, "meta.json"))) {
      console.log(`✓ ${seed.id} (exists)`);
      continue;
    }
    console.log(`… ${seed.id}`);
    try {
      const built = await seed.build();
      await mkdir(clipDir, { recursive: true });
      await rename(built, path.join(clipDir, "input.wav"));
      const meta: ClipMeta = {
        id: seed.id,
        title: seed.title,
        description: seed.description,
        source: seed.source,
        createdAt: new Date().toISOString(),
      };
      await writeFile(
        path.join(clipDir, "meta.json"),
        JSON.stringify(meta, null, 2),
      );
      console.log(`✓ ${seed.id}`);
    } catch (error) {
      failures += 1;
      console.error(`✗ ${seed.id}: ${String(error)}`);
      await rm(clipDir, { recursive: true, force: true });
    }
  }
  await rm(path.join(CACHE_DIR, "seed-tmp"), { recursive: true, force: true });

  console.log(
    failures
      ? `\n${failures} clip(s) failed; rerun to retry.`
      : "\nSeeded. Start the lab with: npm run audio-lab",
  );
  if (failures) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
