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

## git-worktree-terminal

Creates a `git worktree` at `<localPath>/../<repo>-worktrees/pr-<n>[-review]` and starts `claude` with the prompt in a new Terminal.app window. Requires `git`, `jq` and `claude`. Set `PILOTBOAT_DRY_RUN=1` to skip opening Terminal.

Register it in the launcher settings:

```json
{ "id": "git-terminal", "type": "script", "settings": { "executable": "/path/to/git-worktree-terminal", "localPath": "/path/to/repo" } }
```

`localPath` can also come from the per-repository launcher binding.
