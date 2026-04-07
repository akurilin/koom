# koom

## Working Rules

- Do not commit unless the user explicitly asks for a commit.
- Prefer terminal-only workflows. Do not introduce an Xcode project unless the user explicitly asks for one.

## Build Hygiene

- Treat sensible compiler, linker, linter, and build warnings as actionable by default.
- If a warning looks like it may indicate a real source issue, address it during the task instead of ignoring it.
- Examples include concurrency/sendability warnings, API misuse, deprecated APIs with clear replacements, lifetime issues, and warnings that suggest future breakage.
- If a warning is benign or cannot be resolved cleanly in the current task, call that out explicitly in the handoff instead of silently leaving it behind.

## Commands

- Build app bundle: `./scripts/build-app.sh`
- Run app in foreground: `./scripts/run.sh`
