# Architecture

One Swift package, several targets. Dependency direction is strictly
`Pilotboat (App) → {Persistence, SourceGitHub, LauncherOrca, LauncherScript} → Core`, with
`ProcessKit` used by the launchers and the app. `Core` imports nothing but Foundation.

| Target | Owns | Must not |
|---|---|---|
| `Core` | Domain model, `Config`, the engine pipeline (baseline, dedupe, rule matching, settle, approval, queue, launch), prompt rendering, presets, export/import transforms, `Scheduler`. Protocol seams: `EventSource`, `Launcher`, `StateStore`, `ConfigStore`, `SecretStore`, `TimeSource`. In-memory implementations of the stores for tests. | Touch the network, the file system, processes, or AppKit |
| `Persistence` | `GRDBStateStore` (SQLite) and `FileConfigStore` (config.json with one `.bak`) | Contain business rules |
| `ProcessKit` | `CommandRunner` protocol, `ProcessRunner` (argv exec, timeout, SIGTERM→SIGKILL), `PathResolver` (login-shell PATH + fallbacks) | Know about git, orca, or GitHub |
| `SourceGitHub` | `GitHubSource: EventSource` over GraphQL via `URLSession`, token from `SecretStore` | Write to GitHub |
| `LauncherOrca` | `OrcaLauncher: Launcher` driving the `orca` CLI through `CommandRunner` | Shell out directly |
| `LauncherScript` | `ScriptLauncher: Launcher` implementing the JSON stdin/stdout contract | Pass the GitHub token to scripts |
| `Pilotboat` | SwiftUI menu bar app, settings, history, onboarding, notifications, Keychain `SecretStore`, login item, registry wiring | Contain pipeline logic |

## Seams

- Engine talks to persistence only through `StateStore.read/write`, which hands out a `StateAccess` scoped to one transaction. Keep every multi-step update inside a single `write`.
- Launchers are instantiated once per launcher *type*; per-launcher settings arrive in `LaunchRequest.launcherSettings` and as the `settings:` argument of `diagnose` and `open`.
- A launcher that can resume an interrupted launch throws a `RetryableLaunchError`; the engine keeps its token on the `Run` and hands it back in `LaunchRequest.retryToken` on manual retry.
- Every external command is a `Command` (argv array, never a shell string) run through `CommandRunner`, so launchers are unit-tested with a fake runner.
- Time is read from `TimeSource` so settle windows, approval timeouts and daily limits are tested by advancing a fake clock.

## Conventions

- Swift 6 language mode, strict concurrency. Prefer `struct` + `actor`; mark cross-task types `Sendable`.
- Tests use swift-testing (`import Testing`). One test target per module, `Tests/<Target>Tests`.
- No comments except a short WHY that the code cannot express.
- User-facing strings go through `String(localized:)` with keys in `Sources/App/Resources/*.lproj/Localizable.strings` (English base, Japanese translation).
