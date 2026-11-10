# Script launchers

Pilotboat's `script` launcher runs any executable that implements four subcommands.

| Subcommand | Input | Output |
|---|---|---|
| `launch` | request JSON on stdin (see below) | exit 0 and result JSON on stdout, e.g. `{"workspaceRef": "...", "reusedWorkspace": false}` |
| `diagnose` | none | exit 0 if healthy; the first stdout line is shown in diagnostics |
| `capabilities` | none | `{"reuseWorkspace": true, "sendToSession": false}` |
| `open <workspaceRef>` | argument | exit code |

- Non-zero exit is a failure; the last 4 KB of stderr is stored on the run.
- Environment: `PILOTBOAT_RUN_ID` (for `launch`), `PATH` (Pilotboat's resolved search path), `HOME`, and, when set in Pilotboat's own environment, `SSH_AUTH_SOCK`, `TMPDIR`, `LANG`, `LC_ALL`, `USER`, `LOGNAME` and `SHELL`. Nothing else is inherited; `GH_TOKEN` and `GITHUB_TOKEN` are never passed.
- Timeouts: `launch` 120 s, `diagnose` and `open` 30 s, `capabilities` 10 s. On timeout the script's own process receives SIGTERM, then SIGKILL 5 s later if it is still running; child processes it started are not signalled. Pilotboat stops reading output 5 s after the timeout even if a background child still holds stdout open, and the run fails as timed out.
- `capabilities` is queried once per executable and cached until Pilotboat restarts; a failed query is retried next time.

## Launch contract, version 1

The request is a JSON object with these fields. Field names are frozen for version 1; new optional fields may be added, so ignore keys you do not know.

| Field | Type | Notes |
|---|---|---|
| `version` | number | Always `1` for this contract. A breaking change increments it. |
| `runId` | string | UUID of the run; same as `PILOTBOAT_RUN_ID`. |
| `subject` | object | `{"type": "pullRequest", "pullRequest": {...}}` |
| `subject.pullRequest` | object | `host`, `repo` (`owner/name`), `number`, `url`, `title`, `headRef`, `headSHA`, `baseRef`, `isDraft`, `isCrossRepository`, `labels` (array of strings), `author`, `state` (`OPEN`, `CLOSED` or `MERGED`) |
| `repository` | object | `host`, `fullName`, `launcherBinding` (optional) |
| `workspacePolicy` | string | See below. |
| `prompt` | string | Rendered prompt. |
| `previousWorkspaceRef` | string, optional | Workspace of the most recent run for the same pull request that returned one. |
| `previousTerminalHandle` | string, optional | Terminal handle from that run. |
| `launcherSettings` | object | The launcher's settings as configured, including `executable` and `localPath` if set. |
| `retryToken` | string, optional | Set when retrying a failed run. |

Optional fields are omitted when absent. `repository.launcherBinding` is the per-repository binding; when the repository has none, it is filled from `launcherSettings.localPath`, so reading `repository.launcherBinding` is enough to find the local checkout.

The result printed on stdout:

| Field | Type | Notes |
|---|---|---|
| `workspaceRef` | string | Required. Passed back to `open` and as `previousWorkspaceRef` on later runs. |
| `terminalHandle` | string, optional | |
| `reusedWorkspace` | boolean, optional | Defaults to `false`. |
| `sentToExistingSession` | boolean, optional | Defaults to `false`. |
| `retryToken` | string, optional | Stored on the run and sent back as `retryToken` on retry. |

`workspacePolicy` is one of:

- `alwaysNew`: start in a fresh workspace for every run.
- `reuseOrCreate`: use the workspace that has the pull request's head branch checked out, creating it if missing.
- `reusePrevious`: reuse `previousWorkspaceRef` after updating it to `headSHA`; when it is missing or cannot be updated, behave like `alwaysNew`.

Launchers that report `"reuseWorkspace": false` always receive `alwaysNew`.

## git-worktree-terminal

Creates a `git worktree` at `<localPath>/../<repo>-worktrees/pr-<n>` (`reuseOrCreate`) or `pr-<n>-review[-<k>]` (`alwaysNew`) and starts `claude` with the prompt in a new Terminal.app window. For `reusePrevious` it fetches the head branch into `previousWorkspaceRef` and fast-forwards it to `headSHA` (`git merge --ff-only`); if that fails it creates a new review worktree instead. Requires `git`, `jq` and `claude`. Set `PILOTBOAT_DRY_RUN=1` to skip opening Terminal.

Register it in the launcher settings:

```json
{ "id": "git-terminal", "type": "script", "settings": { "executable": "/path/to/git-worktree-terminal", "localPath": "/path/to/repo" } }
```

`localPath` can also come from the per-repository launcher binding.
