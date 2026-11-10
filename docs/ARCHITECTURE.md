# Architecture

One Swift package, several targets. Dependency direction is strictly
`Pilotboat (App) → {Persistence, SourceGitHub, LauncherOrca, LauncherScript} → Core`, with
`ProcessKit` used by the launchers and the app. `Core` imports nothing but Foundation.

| Target | Owns | Must not |
|---|---|---|
| `Core` | Domain model, `Config` and its editing operations (`Config+Editing`), the engine (`Engine` owns transactions and events; `RunPolicy` holds the pure decisions: settle, dispatch plan, baselines), prompt rendering, presets, export/import transforms, `Scheduler`. Protocol seams: `EventSource`, `Launcher`, `StateStore`, `ConfigStore`, `SecretStore`, `TimeSource`. In-memory implementations of the stores for tests, with the same constraints as the SQLite store. | Touch the network, the file system, processes, or AppKit; produce user-facing text (errors are described by an injected `describeError`) |
| `Persistence` | `GRDBStateStore` (SQLite) and `FileConfigStore` (config.json with one `.bak`) | Contain business rules |
| `ProcessKit` | `CommandRunner` protocol, `ProcessRunner` (argv exec, environment allowlist, timeout, SIGTERM→SIGKILL, bounded output drain), `PathResolver` (login-shell PATH + fallbacks), `FakeCommandRunner` for tests | Know about git, orca, or GitHub; pass `GH_TOKEN`/`GITHUB_TOKEN` to children |
| `SourceGitHub` | `GitHubSource: EventSource` over GraphQL via `URLSession`, token from `SecretStore` | Write to GitHub |
| `LauncherOrca` | `OrcaLauncher: Launcher` (policy flows), `OrcaCLI` (typed `orca` commands, argv builders shared by `launch` and `describe`), `Git` (worktree git operations), `OrcaSettings` | Shell out directly |
| `LauncherScript` | `ScriptLauncher: Launcher` implementing the versioned JSON stdin/stdout contract (`ScriptLaunchRequestV1`/`ScriptLaunchResultV1`, documented in `contrib/launchers/README.md`), `ScriptSettings` | Pass the GitHub token to scripts; expose Core types in the contract |
| `Pilotboat` | SwiftUI menu bar app, settings, history, onboarding, notifications, Keychain `SecretStore`, login item, registry wiring | Contain pipeline logic |

## Seams

- Engine talks to persistence only through `StateStore.read/write`, which hands out a `StateAccess` scoped to one transaction. Keep every multi-step update inside a single `write`.
- Launchers are instantiated once per launcher *type*; per-launcher settings arrive in `LaunchRequest.launcherSettings` and as the `settings:` argument of `capabilities`, `diagnose` and `open`. Launcher modules expose typed settings (`OrcaSettings`, `ScriptSettings`) that round-trip through `JSONValue`; the app never reads setting keys by string.
- Library modules throw typed errors with plain-English `errorDescription` for logs; the app maps each case to a localized message (`AppModel.describe`) and injects that mapping into the engine.
- A launcher that can resume an interrupted launch throws a `RetryableLaunchError`; the engine keeps its token on the `Run` and hands it back in `LaunchRequest.retryToken` on manual retry.
- Every external command is a `Command` (argv array, never a shell string) run through `CommandRunner`, so launchers are unit-tested with a fake runner.
- Time is read from `TimeSource` so settle windows, approval timeouts and daily limits are tested by advancing a fake clock.

## Conventions

- Swift 6 language mode, strict concurrency. Prefer `struct` + `actor`; mark cross-task types `Sendable`.
- Tests use swift-testing (`import Testing`). One test target per module, `Tests/<Target>Tests`.
- No comments except a short WHY that the code cannot express.
- User-facing strings go through `String(localized:)` with keys in `Sources/App/Resources/*.lproj/Localizable.strings` (English base, Japanese translation).
