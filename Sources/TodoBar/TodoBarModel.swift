import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

/// Owns the tab list + the active file store.
@MainActor
final class TodoBarModel: ObservableObject {
    @Published private(set) var sources: [TodoSource]
    @Published var selectedID: UUID {
        didSet {
            guard oldValue != selectedID else { return }
            applySelection()
            TodoSourceStore.save(sources: sources, selectedID: selectedID)
        }
    }

    let store: TodoStore

    var selectedSource: TodoSource? {
        sources.first { $0.id == selectedID }
    }

    init() {
        let loaded = TodoSourceStore.load()
        self.sources = loaded.sources
        self.selectedID = loaded.selectedID
        let path = loaded.sources.first(where: { $0.id == loaded.selectedID })?.url
            ?? TodoStore.defaultTodosURL()
        self.store = TodoStore(filePath: path)
    }

    func select(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func addSource(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        // Already open → just select
        if let existing = sources.first(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == resolved
        }) {
            selectedID = existing.id
            return
        }
        let source = TodoSource(url: resolved)
        sources.append(source)
        selectedID = source.id
        TodoSourceStore.save(sources: sources, selectedID: selectedID)
    }

    func removeSource(_ id: UUID) {
        guard sources.count > 1 else { return }
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: idx)
        if selectedID == id {
            selectedID = sources[min(idx, sources.count - 1)].id
        }
        TodoSourceStore.save(sources: sources, selectedID: selectedID)
    }

    func renameSource(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[idx].title = trimmed
        TodoSourceStore.save(sources: sources, selectedID: selectedID)
        objectWillChange.send()
    }

    /// NSOpenPanel for another .md todo file.
    func pickAndAddSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md")].compactMap { $0 }
        panel.title = "Add Todo Markdown File"
        panel.message = "Pick a todos.md / todo.md (or any .md with `- item` lines)"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Menu bar windows need this or the panel sits behind forever
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSource(url: url)
    }

    private func applySelection() {
        guard let source = selectedSource else { return }
        store.setFile(source.url)
    }
}
