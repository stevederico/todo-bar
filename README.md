<p align="center">
  <img src="docs/screenshots/panel-project.png" alt="todo-bar panel showing open markdown todos" width="460" />
</p>

<h1 align="center">todo-bar</h1>

<h3 align="center">mac menu bar app for open items in plain markdown todos</h3>

<p align="center">
  <img src="docs/screenshots/demo.gif" alt="todo-bar switching between project and books tabs" width="400" />
</p>

## What it does

- Tabs for multiple files (default: `~/todos.md`, then `~/Documents/todos.md`)
- **+** tab after the last list takes a path to another `.md` (e.g. `~/books.md`, `~/marketing/todo.md`)
- Right-click tab → Rename / Reveal / Remove
- Shows open items (`- task`) grouped by `##` section; completed stay hidden until **Show Completed**
- **+** / `n` — new to-do is prepended at the top of the first section (pre-header `To-Dos` when present)
- Click the square — mark complete (`- [x]`), move that line to the **end of the file**; **Show Completed** to see / reopen
- Click text to expand; double-click (or right-click → Edit) to rewrite
- Right-click — Mark Complete / Reopen, Edit, Copy, **Delete**
- Drag open items to reorder (when not filtering)
- Live-reloads when the active file changes; tabs persist in UserDefaults
- **Open Window** (`w`) — pop the panel into a normal resizable window (same tabs + data)

Opening or closing the panel or window syncs that file's git remote (fetch; fast-forward if behind; push when ahead). Edits commit and push. Fetch failures stay silent. Diverged branches and overlapping uncommitted files are left alone. **Refresh** (or `r`) forces a check.

Completing an item always appends it to a sibling `CHANGELOG.md` (creates the file if needed).

<p align="center">
  <img src="docs/screenshots/panel-books.png" alt="todo-bar books tab with sample reading list" width="400" />
</p>

## Build & run

```bash
./build.sh
open "build/todo-bar.app"
```

Smoke / unit tests (pure `TodoDocument` + temp-repo store integration — required after logic changes):

```bash
./build.sh --smoke
# or: bash scripts/smoke.sh
```

## Format

- `- item` = open (shown)
- `- [x] item` = completed (line moved to end of file; hidden until Show Completed)
- `## Section` = group header

## Sample data

Screenshots use fake lists in `docs/demo/` (not anyone's real todos). Regenerate:

```bash
bash scripts/render-screenshots.sh
```

## Linux / Omarchy

The [todo-omarchy](https://github.com/stevederico/todo-omarchy) plugin is the Linux port of this app for the Omarchy bar and tiled window.
