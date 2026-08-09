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
- **+** — new to-do goes in the **first** section (top), before any completed lines; commits async
- **Click** circle — mark complete (`- [x]`) and move to bottom of that section; click again to reopen
- **Click** text — expand; **double-click** (or right-click → Edit) to rewrite
- **Reorder** — chevrons (or context menu Move Up/Down) on open items
- Live-reloads when the active file changes; tabs persist in UserDefaults

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
- `- [x] item` = completed (bottom of section; hidden until Show Completed)
- `## Section` = group header

## Sample data

Screenshots use fake lists in `docs/demo/` (not anyone's real todos). Regenerate:

```bash
bash scripts/render-screenshots.sh
```
