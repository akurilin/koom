// lint-staged config. Runs from the repo root.
//
// For files inside the `web` workspace we shell out into that directory so
// ESLint (flat config) and Prettier find their respective config files.
// Staged paths are rewritten to be relative to `web/` before being passed.

import path from "node:path";

function toWebRelative(files) {
  return files
    .map((file) => path.relative("web", file))
    .map((file) => JSON.stringify(file))
    .join(" ");
}

export default {
  "web/**/*.{ts,tsx,js,jsx,mjs,cjs}": (files) => [
    `sh -c 'cd web && npx --no-install eslint --fix ${toWebRelative(files)}'`,
  ],
  "web/**/*.{ts,tsx,js,jsx,mjs,cjs,json,md,css,yml,yaml}": (files) => [
    `sh -c 'cd web && npx --no-install prettier --write ${toWebRelative(files)}'`,
  ],
  "**/*.{sh,bash}": "shellcheck",
};
