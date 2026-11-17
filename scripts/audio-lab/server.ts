#!/usr/bin/env tsx
/*
 * Audio lab: a local listening page for comparing audio cleanup and
 * loudness-normalization chains on real clips.
 *
 *   npm run audio-lab:seed   # once: download the starter clips
 *   npm run audio-lab        # serve http://127.0.0.1:5174
 *
 * Drop audio or video files onto the page to add clips. Every clip is
 * rendered through each chain in lab.ts; the page plays them in sync so
 * you can switch mid-sentence, score them, and pick a favorite. Ratings
 * land in .data/ratings.json.
 */

import { randomBytes } from "node:crypto";
import { createReadStream, createWriteStream, existsSync } from "node:fs";
import {
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import path from "node:path";
import { pipeline } from "node:stream/promises";

import { CHAINS, CLIPS_DIR, LAB_DIR, RATINGS_FILE, TARGET_LUFS } from "./lab";
import {
  type ClipMeta,
  detectTools,
  processClip,
  readMeta,
  type Tools,
  variantsFor,
} from "./process";

const PORT = Number(process.env.AUDIO_LAB_PORT ?? 5174);
const HOST = "127.0.0.1";

let tools: Tools;

// ---------------------------------------------------------------------------
// Processing queue: one clip at a time, in the order they were queued.

const queue: string[] = [];
let active: string | null = null;

function enqueue(clipId: string): void {
  if (active === clipId || queue.includes(clipId)) return;
  queue.push(clipId);
  void drain();
}

async function drain(): Promise<void> {
  if (active) return;
  while (queue.length > 0) {
    active = queue.shift()!;
    const started = Date.now();
    try {
      await processClip(path.join(CLIPS_DIR, active), tools);
      console.log(
        `rendered ${active} in ${((Date.now() - started) / 1000).toFixed(1)}s`,
      );
    } catch (error) {
      console.error(`processing ${active} failed: ${String(error)}`);
    }
    active = null;
  }
}

// ---------------------------------------------------------------------------
// Storage helpers

const CLIP_ID = /^[a-z0-9][a-z0-9-]{0,80}$/;

async function clipIds(): Promise<string[]> {
  if (!existsSync(CLIPS_DIR)) return [];
  const names = await readdir(CLIPS_DIR);
  const ids: string[] = [];
  for (const name of names) {
    if (
      CLIP_ID.test(name) &&
      existsSync(path.join(CLIPS_DIR, name, "meta.json"))
    ) {
      ids.push(name);
    }
  }
  return ids;
}

type Ratings = Record<
  string,
  {
    scores: Record<string, number>;
    best: string | null;
    notes: string;
    updatedAt: string;
  }
>;

async function readRatings(): Promise<Ratings> {
  if (!existsSync(RATINGS_FILE)) return {};
  return JSON.parse(await readFile(RATINGS_FILE, "utf8"));
}

let ratingsWrite = Promise.resolve();
function writeRatings(update: (ratings: Ratings) => void): Promise<void> {
  // Serialize read-modify-write so overlapping saves don't drop each other.
  ratingsWrite = ratingsWrite.then(async () => {
    const ratings = await readRatings();
    update(ratings);
    const partial = `${RATINGS_FILE}.partial`;
    // Prettier's layout, since the file is tracked.
    await writeFile(partial, JSON.stringify(ratings, null, 2) + "\n");
    await rename(partial, RATINGS_FILE);
  });
  return ratingsWrite;
}

function slug(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/\.[a-z0-9]+$/, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40) || "clip"
  );
}

// ---------------------------------------------------------------------------
// HTTP

function sendJSON(
  response: ServerResponse,
  status: number,
  body: unknown,
): void {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(body));
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

async function state() {
  const clips = await Promise.all(
    (await clipIds()).map(async (id) => {
      const clipDir = path.join(CLIPS_DIR, id);
      const meta = await readMeta(clipDir);
      const variants = await variantsFor(clipDir, id, tools);
      // Picks up clips seeded while the server is running.
      if (variants.some((variant) => variant.status === "pending")) {
        enqueue(id);
      }
      return {
        ...meta,
        processing: active === id || queue.includes(id),
        variants,
      };
    }),
  );
  // Your uploads first (newest on top), then the seeded clips.
  clips.sort((a, b) => {
    const seededA = a.source ? 1 : 0;
    const seededB = b.source ? 1 : 0;
    if (seededA !== seededB) return seededA - seededB;
    return seededA
      ? a.id.localeCompare(b.id)
      : b.createdAt.localeCompare(a.createdAt);
  });
  return {
    targetLUFS: TARGET_LUFS,
    tools,
    chains: CHAINS.map(({ id, label, retired }) => ({
      id,
      label,
      retired: !!retired,
    })),
    clips,
    ratings: await readRatings(),
  };
}

async function handle(request: IncomingMessage, response: ServerResponse) {
  const url = new URL(request.url ?? "/", `http://${HOST}`);
  const parts = url.pathname.split("/").filter(Boolean);

  if (request.method === "GET" && url.pathname === "/") {
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    createReadStream(path.join(LAB_DIR, "ui.html")).pipe(response);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/state") {
    sendJSON(response, 200, await state());
    return;
  }

  // POST /api/clips?filename=...  (raw file body)
  if (request.method === "POST" && url.pathname === "/api/clips") {
    const filename = url.searchParams.get("filename") ?? "upload";
    const extension = (path
      .extname(filename)
      .toLowerCase()
      .match(/^\.[a-z0-9]{1,8}$/) ?? [".bin"])[0];
    const id = `${slug(filename)}-${randomBytes(3).toString("hex")}`;
    const clipDir = path.join(CLIPS_DIR, id);
    await mkdir(clipDir, { recursive: true });
    await pipeline(
      request,
      createWriteStream(path.join(clipDir, `input${extension}`)),
    );
    const meta: ClipMeta = {
      id,
      title: filename.replace(/\.[^.]+$/, ""),
      description: "",
      createdAt: new Date().toISOString(),
    };
    await writeFile(
      path.join(clipDir, "meta.json"),
      JSON.stringify(meta, null, 2),
    );
    enqueue(id);
    sendJSON(response, 201, { id });
    return;
  }

  // /api/clips/:id[/retry]
  if (
    parts[0] === "api" &&
    parts[1] === "clips" &&
    parts[2] &&
    CLIP_ID.test(parts[2])
  ) {
    const id = parts[2];
    const clipDir = path.join(CLIPS_DIR, id);
    if (!existsSync(path.join(clipDir, "meta.json"))) {
      sendJSON(response, 404, { error: "no such clip" });
      return;
    }
    if (request.method === "PATCH" && parts.length === 3) {
      const body = JSON.parse(await readBody(request)) as Partial<ClipMeta>;
      const meta = await readMeta(clipDir);
      if (typeof body.title === "string") meta.title = body.title.slice(0, 200);
      if (typeof body.description === "string") {
        meta.description = body.description.slice(0, 2000);
      }
      await writeFile(
        path.join(clipDir, "meta.json"),
        JSON.stringify(meta, null, 2),
      );
      sendJSON(response, 200, meta);
      return;
    }
    if (request.method === "DELETE" && parts.length === 3) {
      if (active === id) {
        sendJSON(response, 409, {
          error: "clip is rendering; try again shortly",
        });
        return;
      }
      const index = queue.indexOf(id);
      if (index >= 0) queue.splice(index, 1);
      await rm(clipDir, { recursive: true, force: true });
      await writeRatings((ratings) => {
        delete ratings[id];
      });
      sendJSON(response, 200, { ok: true });
      return;
    }
    if (request.method === "POST" && parts[3] === "retry") {
      const outDir = path.join(clipDir, "out");
      if (existsSync(outDir)) {
        for (const name of await readdir(outDir)) {
          if (name.endsWith(".error")) await rm(path.join(outDir, name));
        }
      }
      enqueue(id);
      sendJSON(response, 200, { ok: true });
      return;
    }
  }

  // PUT /api/ratings/:id
  if (
    request.method === "PUT" &&
    parts[0] === "api" &&
    parts[1] === "ratings"
  ) {
    const id = parts[2];
    if (!id || !CLIP_ID.test(id)) {
      sendJSON(response, 400, { error: "bad clip id" });
      return;
    }
    const body = JSON.parse(await readBody(request));
    // The original is the reference, not a candidate, so it isn't rateable.
    const chainIds = new Set(
      CHAINS.map((chain) => chain.id).filter((id) => id !== "original"),
    );
    const scores: Record<string, number> = {};
    for (const [chainId, score] of Object.entries(body.scores ?? {})) {
      if (chainIds.has(chainId) && [1, 2, 3, 4, 5].includes(score as number)) {
        scores[chainId] = score as number;
      }
    }
    const best = chainIds.has(body.best) ? (body.best as string) : null;
    const notes =
      typeof body.notes === "string" ? body.notes.slice(0, 5000) : "";
    await writeRatings((ratings) => {
      ratings[id] = {
        scores,
        best,
        notes,
        updatedAt: new Date().toISOString(),
      };
    });
    sendJSON(response, 200, { ok: true });
    return;
  }

  // GET /clips/:id/out/:file.wav
  if (
    request.method === "GET" &&
    parts[0] === "clips" &&
    parts.length === 4 &&
    CLIP_ID.test(parts[1]) &&
    parts[2] === "out" &&
    /^[a-z0-9-]+\.wav$/.test(parts[3])
  ) {
    const file = path.join(CLIPS_DIR, parts[1], "out", parts[3]);
    if (!existsSync(file)) {
      sendJSON(response, 404, { error: "not found" });
      return;
    }
    response.writeHead(200, {
      "Content-Type": "audio/wav",
      "Content-Length": (await stat(file)).size,
      // Render keys change whenever a chain changes, so files are immutable.
      "Cache-Control": "max-age=31536000, immutable",
    });
    createReadStream(file).pipe(response);
    return;
  }

  sendJSON(response, 404, { error: "not found" });
}

async function main(): Promise<void> {
  await mkdir(CLIPS_DIR, { recursive: true });
  tools = await detectTools();
  const missing = Object.entries(tools)
    .filter(([, available]) => !available)
    .map(([name]) => name);
  if (missing.length) {
    console.log(
      `Chains needing these tools are skipped: ${missing.join(", ")} (see README).`,
    );
  }

  const ids = await clipIds();
  if (ids.length === 0) {
    console.log(
      "No clips yet. Run `npm run audio-lab:seed` or drop files on the page.",
    );
  }
  ids.forEach(enqueue);

  createServer((request, response) => {
    handle(request, response).catch((error) => {
      console.error(error);
      if (!response.headersSent)
        sendJSON(response, 500, { error: String(error) });
      else response.end();
    });
  }).listen(PORT, HOST, () => {
    console.log(`Audio lab: http://${HOST}:${PORT}`);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
