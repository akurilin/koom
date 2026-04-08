// lint-staged config. Runs from the repo root.
//
// ESLint is scoped to the `web` workspace because its flat config only
// resolves when run from that directory. We shell out into `web/` and
// rewrite staged paths to be relative before passing them to eslint.
//
// Prettier runs repo-wide from the root using the root .prettierrc and
// .prettierignore. Prettier's per-file config lookup still honours
// web/.prettierrc when files inside web/ are formatted, so the two
// configs stay consistent without the workspaces fighting each other.

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
  "**/*.{ts,tsx,js,jsx,mjs,cjs,json,md,mdx,css,yml,yaml}": "prettier --write",
  "**/*.{sh,bash}": "shellcheck",
};
