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
- **+** adds another `.md` (e.g. `books.md`, `deals.md`, `marketing/todo.md`)
- Right-click tab → Rename / Reveal / Remove
- Shows open items (`- task`) grouped by `##` section; completed stay hidden until **Show Completed**
- **+** — reveals New To-Do field under the tabs; appends to last section; commits
- **Click** — expand truncated text; **double-click** (or right-click → Edit) to rewrite; commits
- **Complete** — writes `- [x] task`, moves to bottom of section; if `CHANGELOG.md` exists beside the file or at git root, logs under today (`MM/DD/YY`, 2-space indent); `git commit`s. Click again to reopen
- **Reorder** — drag open items within a section; rewrites + commits
- Live-reloads when the active file changes
- Tabs persist in UserDefaults

<p align="center">
  <img src="docs/screenshots/panel-books.png" alt="todo-bar books tab with sample reading list" width="400" />
</p>

## Build & run

```bash
./build.sh
open "build/todo-bar.app"
```

Smoke (parse + add/complete/edit against a temp git repo, asserts UI unlocks without waiting on git):

```bash
./build.sh --smoke
# or: bash scripts/smoke.sh
```

## Format

- `- item` = open (shown)
- `- [x] item` = completed (bottom of section; hidden until Show Completed)
- `## Section` = group header

## Sample data

Screenshots use fake lists in `docs/demo/` (not anyone's real todos). Regenerate:

```bash
bash scripts/render-screenshots.sh
```
