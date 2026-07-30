# Repository scripts

The root `package.json` is koom's primary task interface. Prefer `npm run <task>`
for routine development, validation, database, and infrastructure commands, and
expose new recurring workflows there so contributors have one place to discover
them.

This directory still exists because those npm tasks need implementations that
do not belong in `package.json`:

- TypeScript and JavaScript programs implement operational workflows such as
  `doctor`, R2 setup, and Vercel configuration checks.
- Shell scripts coordinate tools or operating-system behavior that is awkward
  to express as an npm command, such as the cross-platform test runner.
- `build-app.sh`, `run.sh`, `install-app.sh`, and `setup-dev-codesign.sh` are
  stable compatibility entry points from before the Swift app moved into
  `client/`. They delegate to the native implementations in `client/scripts/`.

Direct script execution remains useful for low-level macOS client operations
and backwards compatibility. It should not become a second general-purpose
command catalog: add routine top-level tasks to `package.json`, with the
implementation here when it needs more than a short command.
