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
//
// Swift files go through `swift format` (Apple's official formatter,
// ships with the Swift toolchain as the `swift format` subcommand).
// The formatter reads `.swift-format` at the repo root and supports
// in-place rewriting of staged files. We then run `swift format lint`
// on the same files to surface anything the auto-fixer couldn't
// handle (mainly LineLength and naming warnings) as informational
// output — lint is non-strict so warnings don't block the commit.

import path from "node:path";

function toWebRelative(files) {
  return files
    .map((file) => path.relative("web", file))
    .map((file) => JSON.stringify(file))
    .join(" ");
}

function quoteFiles(files) {
  return files.map((file) => JSON.stringify(file)).join(" ");
}

export default {
  "web/**/*.{ts,tsx,js,jsx,mjs,cjs}": (files) => [
    `sh -c 'cd web && npx --no-install eslint --fix ${toWebRelative(files)}'`,
  ],
  "**/*.{ts,tsx,js,jsx,mjs,cjs,json,md,mdx,css,yml,yaml}": "prettier --write",
  "**/*.{sh,bash}": "shellcheck",
  "supabase/migrations/*.sql": (files) =>
    `npx --no-install squawk ${quoteFiles(files)}`,
  "client/**/*.swift": (files) => {
    const quoted = quoteFiles(files);
    return [
      `swift format format --in-place ${quoted}`,
      `swift format lint ${quoted}`,
    ];
  },
};
