# UI design

This document is the contract for the app layer (`Sources/App`). The engine, stores, sources and launchers are unchanged; the UI maps their concepts onto a smaller, task-oriented vocabulary.

## Principles

1. **One home.** The menu bar popover is the home: what needs me now, what happened recently, is monitoring on. Everything else is one click away.
2. **One behavior, one place.** "When X happens in these repos, do Y, ask me first" is edited on one screen (an *Automation*). Repositories and launchers are referenced from it, not configured around it.
3. **User vocabulary, not engine vocabulary.** No "rule", "priority", "settle", "workspace policy", "baseline", "dedupe". Engine terms stay in code.
4. **Progressive disclosure.** Defaults work. Filters, timing and advanced options are collapsed and labelled in plain words.
5. **Status is visible, actions are near it.** Every list row shows state with an icon + color; the action for that state (Run / Skip / Retry / Open) sits on the row.
6. **Safe by default.** Anything that launches an agent or changes GitHub-facing behavior says so and asks.
7. **Native macOS.** System controls, `Form` with grouped style, sidebar navigation, SF Symbols, semantic colors, `ContentUnavailableView` for empty states, standard window sizes. No custom chrome.

## Vocabulary

| UI term | Engine term | Notes |
|---|---|---|
| Automation | `Rule` | "When ⟨trigger⟩ in ⟨repositories⟩ → ⟨action⟩, ⟨approval⟩" |
| Trigger | `EventKind` | "Someone requests my review" / "Someone reviews my pull request" |
| Filters | `Condition` | Reviewer type, drafts, labels |
| Action | launcher + workspace policy + prompt | "Start an agent in a new worktree" / "Continue in the pull request's worktree" |
| Instructions | `PromptTemplate.body` | Edited inline in the automation; sharing is a detail |
| Ask first / Run automatically | `executionMode` | |
| Wait for more reviews | `settleSeconds` | Shown in minutes, under Timing |
| Order ("higher wins") | `priority` | Drag to reorder; the list order is the priority |
| Run | `Run` | Row in Activity |
| Waiting for you | `pendingApproval` | |
| Held until tomorrow | `held` | Daily limit |
| Agent launcher | `Launcher` | Settings only |
| Repository | `Repository` | |
| Health | diagnostics + status | |

Run state labels and icons (shared component `RunStateBadge`):

| State | Label | Symbol | Color |
|---|---|---|---|
| settling | Collecting reviews… | `clock` | secondary |
| pendingApproval | Waiting for you | `hand.raised.fill` | orange |
| queued / launching | Starting… | `arrow.triangle.2.circlepath` | blue |
| launched | Started | `checkmark.circle.fill` | green |
| held | Held until tomorrow | `pause.circle` | secondary |
| failed | Failed | `xmark.octagon.fill` | red |
| skipped | Skipped · ⟨reason⟩ | `minus.circle` | secondary |

Skip reasons in words: you skipped it / no answer in 24 hours / pull request was closed / monitoring was off / automation was removed / pull request is from a fork.

## Surfaces

### 1. Menu bar popover (home) — `MenuBarExtra`, `.window` style, 360 pt wide

```
┌──────────────────────────────────────┐
│ ● Monitoring              [Pause ▾]  │  header: status dot + text; Pause menu: 30 min / 1 h / until tomorrow / Turn off; when off: [Turn on]
│   Checked 2 min ago · 1 review request waiting                  (secondary caption; error text in red when status.lastError)
├──────────────────────────────────────┤
│ WAITING FOR YOU (2)                  │  section, only when non-empty
│ ┌──────────────────────────────────┐ │
│ │ fs-student-web #4152             │ │  card: repo#number (bold), PR title (1 line), automation name (caption)
│ │ chore: Update GraphQL Schema     │ │
│ │ Review requested · 3 min ago     │ │
│ │            [Skip]      [Run]     │ │  Run is the default-styled button
│ └──────────────────────────────────┘ │
├──────────────────────────────────────┤
│ RECENT                               │  last 5 runs, compact rows: badge, repo#number, relative time; click → opens main window on that run
│ ✓ fs-student-web #4150 · Started · 1 h ago
│ ✕ mikan-api #8049 · Failed · yesterday
│   (empty state: "Nothing has happened yet")
├──────────────────────────────────────┤
│ Open Pilotboat      Check now   ⚙ ⏻ │  footer: text button, text button, settings (gear) and quit (power) icon buttons
└──────────────────────────────────────┘
```

- Turning monitoring on from the popover shows a confirmation sheet with one checkbox: "Also handle review requests that are already waiting" (default off). Explain in one line why.
- Status icon in the menu bar: `sailboat.fill` on, `sailboat` (outline) off/paused, `sailboat.fill` with a red badge dot when `lastError` or when runs wait for approval (badge count via `MenuBarExtra` label text when > 0).
- The popover never shows engine internals; "Checked" is the last tick time.

### 2. Main window — `Window("Pilotboat", id: "main")`, 980 × 640 default, `NavigationSplitView`

Sidebar (section-less, icon + label):

- **Activity** (`list.bullet.rectangle`) — default selection
- **Automations** (`bolt.badge.automatic`)
- **Repositories** (`folder`)
- **Health** (`heart.text.square`)

Sidebar footer: monitoring status line (same as popover header, compact).

#### 2a. Activity

Two-pane: list left (full width list inside the content column, min 320), detail right.

List: `Table`-like rows, newest first, grouped by day headers (Today / Yesterday / date). Row: `RunStateBadge`, `repo #number`, PR title (secondary, 1 line), automation name (caption), relative time (trailing). Filter segmented control above the list: All · Waiting · Failed. Empty states via `ContentUnavailableView` ("No runs yet", "Nothing is waiting for you", "No failures").

Detail (for selected run): header with PR title (title2), `repo #number · branch`, state badge with timestamp. Primary actions by state: Waiting → [Skip] [Run]; Failed → [Retry]; Started → [Open worktree]; always → [Open on GitHub]. Then sections:

- **What triggered it**: the collected events as a short list (kind, actor, time). For review-submitted runs: "3 reviews from alice, bot/renovate" style summary.
- **Instructions sent to the agent**: monospaced, scrollable, 8 lines max then "Show more".
- **Result**: launcher output (worktree, terminal) or the error text (selectable, red tint) when failed.

#### 2b. Automations

List (left, min 300): ordered, drag to reorder, header caption "When several automations match, the one higher in the list runs". Row: enabled toggle, name, one-line summary built from the automation: "Review requested · All repositories · Ask first". Disabled rows dimmed. Unsupported trigger → warning icon with help text. Toolbar: [+ New automation ▾] (menu: "When someone requests my review", "When someone reviews my pull request"), [Duplicate], [Delete].

Editor (right): a `Form` with grouped style, sections in reading order:

1. **Name** — text field; **Enabled** toggle (trailing).
2. **When** — Trigger picker (two choices, with one-line descriptions). **Repositories**: segmented "All monitored" / "Only…" and, when Only, a chip list of chosen repositories with a `+` menu listing monitored repositories. **Filters** (disclosure, collapsed when all default): Reviewer: Anyone / People only / Bots only; "Include draft pull requests" toggle; "Only with labels" and "Not with labels" token fields.
3. **Then** — **Action**: picker "Start an agent in a new worktree" / "Continue in the pull request's worktree" with a caption explaining each (the second: "Reuses the worktree and running agent for the PR's branch when there is one"). Launcher picker only when more than one launcher is configured (else a caption "Using Orca"); inline warning when the chosen launcher can't reuse worktrees. **Instructions**: `TextEditor` (monospaced, 6–12 lines, grows), toolbar under it: "Insert ▾" menu of variables grouped (Pull request / Repository / Review, with the review group disabled for the review-requested trigger), and a yellow inline note when `{{pr.title}}` is used ("The title is written by the PR author and can contain instructions for the agent"). Validation errors inline under the editor (unsupported variables for this trigger). If this instruction text is shared by other automations, a caption "Also used by N other automations — edits apply to all" with a "Make a copy" button.
4. **Before starting** — radio: "Ask me first (recommended)" / "Run automatically". Choosing automatic shows a confirmation sheet with the safety text and a "Run automatically" destructive-styled confirm.
5. **Timing** (disclosure, collapsed) — "Wait for more reviews" stepper in minutes (0–10) with caption "Reviews that arrive within this window are handled together" (hidden for the review-requested trigger).
6. Footer bar: [Test with a pull request…] left; [Revert] [Save] right; Save disabled until dirty and valid. Unsaved changes prompt when switching selection.

**Test sheet**: URL field, [Preview] (dry run) shows: match verdict with reason (plain words, e.g. "Would not run: this pull request is a draft"), which automation would run instead if outranked, the rendered instructions, and the commands the launcher would execute; [Start now] (secondary, confirms) performs a trial run and shows a link to Activity.

#### 2c. Repositories

List (left): name with monitoring toggle, caption with the Orca binding state ("Linked to Orca" / "Not linked"). Toolbar: [+] opens a sheet: `owner/name` field with validation and, when Orca is available, a "From Orca" list of repositories not yet added (checkbox rows, pre-filled names) — adding from this list links them automatically. [−] remove with confirmation.

Detail (right), `Form`:

1. **Monitoring** toggle with caption "Events from this repository are ignored while off".
2. **Automations here** — one row per trigger: trigger name → which automation applies (name) or "Ignored here" or "None", with a trailing menu: "Ignore this trigger here" / "Stop ignoring", "Customize for this repository…" (duplicates the applying automation scoped to this repo, opens it in Automations), "Open automation".
3. **Agent launcher** — Orca: picker of Orca repositories (auto-selected by canonical key; shows the local path as caption); Script launcher: folder picker for the local checkout. Only launchers that exist are shown.

#### 2d. Health

Single scrollable page of grouped cards; a [Check again] button in the toolbar.

1. **Status** — monitoring, last check, next check, last error (red), API quota remaining ("4,778 of 5,000 requests this hour"), consecutive failures (only if > 0).
2. **GitHub** — account, token source, scopes note; [Sign out] / [Sign in…].
3. **Tools** — git / orca / claude rows: name, version, path; red when missing with a one-line fix hint.
4. **Agent launchers** — each launcher's diagnostics (from `Launcher.diagnose`).
5. **Troubleshooting** — [Export logs…], [Reveal configuration folder], resolved PATH in a disclosure.

### 3. Settings — `Settings` scene (⌘,), 4 tabs

- **General**: Start at login; Notifications; Check GitHub every ⟨2 min⟩ (picker: 1, 2, 5, 10, 15 min); Limits group: "Run at most ⟨3⟩ agents at the same time", "Start at most ⟨20⟩ agents per day"; Review requests: "Include requests sent to my teams"; Ignore reviews from: token list (default dependabot[bot]).
- **Account**: GitHub sign-in (gh CLI button / PAT field) with scopes note; signed-in state with [Sign out].
- **Launchers**: list of launchers with [+ ▾] (Orca / Script); Orca form: agent, model, effort (optional), `orca` path (optional), setup hooks for others' PRs / own PRs (Skip / Inherit / Run with captions), activate window toggle; Script form: executable (file picker), default local path, capabilities read-out, [Test] (runs diagnose). Deleting a launcher used by an automation is blocked with a message naming it.
- **Data**: Export settings… / Import settings… (policy sheet before import, summary after); the configuration folder path.

### 4. First run — `Window("Welcome", id: "setup")`, 560 × 520, opened automatically until completed

Four steps, progress dots, Back/Continue:

1. **Welcome + GitHub** — one paragraph of what Pilotboat does (read-only, launches agents for you, asks first). Sign in: [Use gh CLI] primary when `gh` is on PATH, PAT field as alternative; scopes note. Continue enabled when signed in.
2. **Agent launcher** — auto-detects Orca (shows version) → "Use Orca" selected; agent id field (default claude). Alternative "Use a script" with file picker and a link to the bundled sample. Tool check rows (git / claude) inline; missing tools block Continue with a hint.
3. **Repositories** — when Orca is available: checkbox list of Orca repositories (pre-checked none), plus an `owner/name` field for others; otherwise just the field. Added repositories list below.
4. **Automations** — the two presets as cards with toggles (both on by default here), each with its instruction text in a disclosure; then "Review requests already waiting: ⟨N⟩" with a checkbox "Handle them too" (default off, caption why). [Finish] completes onboarding, starts monitoring, opens the main window on Activity.

## Shared components (`Sources/App/Components/`)

- `RunStateBadge(run:)` — label + symbol + color per the table above.
- `RunRow(run:)` — compact row used by popover and Activity.
- `PullRequestTitle(ref:)` — "repo #number" + title styles.
- `StatusLine(status:)` — monitoring dot + text + last check.
- `SectionCard` — `GroupBox` wrapper with a title and optional trailing control.
- `Chip` / `ChipList` — small capsule tags for repositories and labels.
- `RelativeDate` — `Text(date, style: .relative)` helper with "ago".
- `Captioned(title, caption)` — row with a secondary explanation.

## Conventions

- Strings: `Text("…", bundle: .resources)` / `String(localized:bundle: .resources)`; keys = English text.
- Spacing: 16 pt page margins, 8 pt within groups, 24 pt between sections. Use `Form` + `.formStyle(.grouped)` for editors; plain `List` for navigation lists.
- Minimum window content sizes are set so nothing truncates at default size.
- Destructive or launching actions confirm with a sheet or alert whose confirm button names the action ("Start agent", "Delete automation").
- Errors show inline near the cause; global errors (bootstrap, GitHub auth) show in the popover header and Health.
