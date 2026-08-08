#!/usr/bin/env bash
# Render README screenshots from docs/demo/*.md (never the user's real todos).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/TodoBar"
SHOTDIR="$ROOT/docs/screenshots"
DEMO="$ROOT/docs/demo"
OUT="/tmp/todo-bar-render-$$"
MAIN="/tmp/todo-bar-render-main-$$.swift"

mkdir -p "$SHOTDIR"

cat > "$MAIN" << SWIFT
import AppKit
import SwiftUI
import Foundation

@main
struct RenderMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let demoDir = URL(fileURLWithPath: "$DEMO")
        let project = demoDir.appendingPathComponent("project.md")
        let books = demoDir.appendingPathComponent("books.md")
        let projectID = UUID()
        let booksID = UUID()
        let sources: [TodoSource] = [
            TodoSource(id: projectID, title: "project", path: project.path),
            TodoSource(id: booksID, title: "books", path: books.path),
        ]
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: "todo-bar.sources")
        }

        let tab = CommandLine.arguments.dropFirst().first ?? "project"
        let out = CommandLine.arguments.dropFirst().dropFirst().first
            ?? "$SHOTDIR/panel-\(tab).png"
        let selected = tab == "books" ? booksID : projectID
        UserDefaults.standard.set(selected.uuidString, forKey: "todo-bar.selectedSourceID")

        let model = TodoBarModel()
        let size = NSSize(width: 460, height: 580)
        let view = ContentView(model: model)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderFront(nil)

        let until = Date().addingTimeInterval(1.0)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("no bitmap rep\\n", stderr); exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("png encode fail\\n", stderr); exit(1)
        }
        try! data.write(to: URL(fileURLWithPath: out))
        print("wrote \\(out) bytes=\\(data.count)")
    }
}
SWIFT

swiftc -O \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework SwiftUI -framework AppKit -framework Combine \
  -o "$OUT" \
  "$SRC/TodoStore.swift" \
  "$SRC/TodoSource.swift" \
  "$SRC/TodoBarModel.swift" \
  "$SRC/ContentView.swift" \
  "$MAIN"

"$OUT" project "$SHOTDIR/panel-project.png"
"$OUT" books "$SHOTDIR/panel-books.png"

if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -hide_banner -loglevel error \
    -loop 1 -t 1.5 -i "$SHOTDIR/panel-project.png" \
    -loop 1 -t 1.5 -i "$SHOTDIR/panel-books.png" \
    -filter_complex "[0:v]scale=400:-1:flags=lanczos,fps=8,format=rgba[a];[1:v]scale=400:-1:flags=lanczos,fps=8,format=rgba[b];[a][b]concat=n=2:v=1:a=0,split[s0][s1];[s0]palettegen=max_colors=64:stats_mode=single[p];[s1][p]paletteuse=dither=none" \
    "$SHOTDIR/demo.gif"
  echo "wrote $SHOTDIR/demo.gif"
fi

rm -f "$OUT" "$MAIN"
echo "Screenshots in $SHOTDIR"
