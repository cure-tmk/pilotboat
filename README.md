# Pilotboat

A macOS menu bar app that watches GitHub pull request events (review requests, submitted reviews) and launches a local coding agent in the right worktree with the right prompt.

Status: pre-alpha. Builds and runs locally; not yet signed, notarized, or distributed.

## How it works

- **Source** polls GitHub (GraphQL, read-only) for review requests addressed to you and reviews submitted on your PRs.
- **Rules** map an event kind, a repository scope, and conditions to a **Prompt Template** and a **Launcher**.
- **Launchers** create the worktree and start the agent: the built-in Orca launcher drives the `orca` CLI; the Script launcher runs any executable that implements a small JSON contract (see `contrib/launchers/`).
- Every run is recorded. Each automation chooses whether a run waits for your approval in a notification or starts automatically.

Pilotboat never writes to GitHub. Posting comments or pushing is the agent's job.

## Build and run locally

Requires macOS 14+, Swift 6 toolchain (Xcode Command Line Tools are enough).

```sh
swift test                # unit tests for every module
Scripts/bundle.sh         # builds .build/Pilotboat.app (ad-hoc signed)
open .build/Pilotboat.app
```

Settings and state live in `~/Library/Application Support/io.github.cure-tmk.pilotboat/`. The GitHub token is stored in the Keychain only.

## Layout

See `docs/ARCHITECTURE.md`.

## License

MIT
