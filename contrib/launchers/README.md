# Script launchers

Pilotboat's `script` launcher runs any executable that implements four subcommands.

| Subcommand | Input | Output |
|---|---|---|
| `launch` | `LaunchRequest` JSON on stdin | exit 0 and `LaunchResult` JSON on stdout: `{"workspaceRef": "...", "terminalHandle": null, "reusedWorkspace": false, "sentToExistingSession": false}` |
| `diagnose` | none | exit 0 if healthy; the first stdout line is shown in diagnostics |
| `capabilities` | none | `{"reuseWorkspace": true, "sendToSession": false}` |
| `open <workspaceRef>` | argument | exit code |

- Non-zero exit is a failure; the last 4 KB of stderr is stored on the run.
- Environment: `PILOTBOAT_RUN_ID` and the resolved `PATH`. No GitHub token is passed.
- `launch` has a 120 s timeout. The request contains `launcherSettings` (including `localPath`, if set) and `repository.launcherBinding`.
- `subject` is `{"type": "pullRequest", "pullRequest": {...}}`; dates are ISO 8601.
- `retryToken` is set when retrying a failed run; a `LaunchResult` may return `retryToken` to have it stored on the run.
- `workspacePolicy` is one of:
  - `alwaysNew`: start in a fresh workspace for every run.
  - `reuseOrCreate`: use the workspace that has the pull request's head branch checked out, creating it if missing.
  - `reusePrevious`: reuse `previousWorkspaceRef` (the workspace of the most recent run for the same pull request) after updating it to `headSHA`; when it is missing or cannot be updated, behave like `alwaysNew`.
- `previousWorkspaceRef` and `previousTerminalHandle` come from the most recent run for the same pull request that returned a workspace, or are absent.
- Launchers that report `"reuseWorkspace": false` always receive `alwaysNew`.

## git-worktree-terminal

Creates a `git worktree` at `<localPath>/../<repo>-worktrees/pr-<n>` (`reuseOrCreate`) or `pr-<n>-review[-<k>]` (`alwaysNew`) and starts `claude` with the prompt in a new Terminal.app window. For `reusePrevious` it fetches the head branch into `previousWorkspaceRef` and fast-forwards it to `headSHA` (`git merge --ff-only`); if that fails it creates a new review worktree instead. Requires `git`, `jq` and `claude`. Set `PILOTBOAT_DRY_RUN=1` to skip opening Terminal.

Register it in the launcher settings:

```json
{ "id": "git-terminal", "type": "script", "settings": { "executable": "/path/to/git-worktree-terminal", "localPath": "/path/to/repo" } }
```

`localPath` can also come from the per-repository launcher binding.
