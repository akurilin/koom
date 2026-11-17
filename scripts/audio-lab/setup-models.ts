#!/usr/bin/env tsx
/*
 * Installs the audio lab's Python model helpers (DPDFNet, ClearerVoice,
 * Sidon), each in its own pinned uv environment under .data/envs/, the
 * way the app would install a separate helper tool. Needs `uv`
 * (brew install uv). Model weights download on first use into .data/.
 *
 *   npm run audio-lab:models
 *
 * About 1.7 GB of environments plus about 1.5 GB of weights. The lab
 * skips any helper that isn't installed.
 */

import path from "node:path";

import { PYTHON_DIR, PYTHON_HELPERS } from "./lab";
import { pythonEnv, run } from "./process";

async function main(): Promise<void> {
  for (const helper of PYTHON_HELPERS) {
    console.log(`Installing ${helper} ...`);
    await run(
      "uv",
      ["sync", "--frozen", "--project", path.join(PYTHON_DIR, helper)],
      { env: pythonEnv(helper) },
    );
  }
  console.log("Done. Restart `npm run audio-lab` to render the new chains.");
}

main().catch((error) => {
  console.error(String(error));
  process.exit(1);
});
