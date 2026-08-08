# Dashu

**Dashu** = character · **todo-bar** = product

Flat **2D vector** packaging kyara (not 3D). Sticky-note checklist spirit who lives in the menu bar and checks open `-` items off.

## Official assets

| File | Use |
|------|-----|
| **`dashu.jpg`** | Master art (name on tummy) |
| **`todo-bar.jpg`** | Same master (README) |
| **`dashu-appicon.jpg`** | Cropped + centered square (built from master) |
| **`dashu-centered.jpg`** | Tighter centered marketing square |

## Generated icons (`scripts/build-icons.sh`)

From `dashu.jpg` → crop content, center on square:

| File | Use |
|------|-----|
| `Resources/AppIcon-1024.png` | Master app icon |
| `Resources/AppIcon.icns` | Finder / Accessibility / Dock |
| `Resources/StatusBarIcon.png` (+ `@2x`) | Menu bar (head crop) |
| `Resources/StatusBarIcon-full.png` (+ `@2x`) | Menu bar (full body) |

`./build.sh` runs icon generation automatically.
