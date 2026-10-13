# Detection fixtures

Each folder is a minimal project. `expected.json` lists the ranked proposals the detectors must
return (`label`, `argv` or `shell`, `resolvedScript`, `source`, `predictedPort`). Detectors read these
files and **never execute them** — `malicious-curl-sh` must be proposed verbatim and never run.

Seeded: `next-pnpm`, `malicious-curl-sh`.

Still to add (AGENTS.md §10):

- vite-npm, astro-yarn, remix-bun
- pnpm-monorepo (2 workspaces), turbo-monorepo
- rails-bin-dev, django-venv, flask (port 5000 warning), laravel
- procfile-dev, makefile-targets, justfile, compose
- npm with a `predev` hook
- an unreadable file (create with `chmod 000` in the test, not in git)
- a 5 MB `package.json` (generate in the test to keep the repo small; see `FixtureTests.testFileSnapshotEnforcesSizeCap`)
