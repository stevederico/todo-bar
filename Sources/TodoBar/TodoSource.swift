import Foundation

/// A registered todo markdown file shown as a tab.
struct TodoSource: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// Absolute path to the .md file.
    var path: String

    var url: URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    init(id: UUID = UUID(), title: String, path: String) {
        self.id = id
        self.title = title
        self.path = (path as NSString).standardizingPath
    }

    init(url: URL, title: String? = nil) {
        let resolved = url.resolvingSymlinksInPath()
        self.id = UUID()
        self.path = resolved.path
        self.title = title ?? Self.defaultTitle(for: resolved)
    }

    /// Capitalize each word for tab labels (`books` → `Books`, `my list` → `My List`).
    static func tabTitle(_ title: String) -> String {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        return raw.split(whereSeparator: \.isWhitespace)
            .map { word in
                var s = String(word)
                if let first = s.first {
                    s.replaceSubrange(s.startIndex...s.startIndex, with: String(first).uppercased())
                }
                return s
            }
            .joined(separator: " ")
    }

    /// `Todos/todos.md` → "Todos"; `marketing/todo.md` → "marketing"; `books.md` → "books".
    static func defaultTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let lower = base.lowercased()
        if lower == "todo" || lower == "todos" || lower == "to-do" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return base
    }
}

enum TodoSourceStore {
    private static let key = "todo-bar.sources"
    private static let selectedKey = "todo-bar.selectedSourceID"

    static func load() -> (sources: [TodoSource], selectedID: UUID) {
        let defaults = UserDefaults.standard
        var sources: [TodoSource] = []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([TodoSource].self, from: data),
           !decoded.isEmpty {
            sources = decoded
        } else {
            sources = [defaultSource()]
            save(sources: sources)
        }

        // Keep all registered tabs, including paths that do not exist yet.
        let selected: UUID
        if let raw = defaults.string(forKey: selectedKey),
           let id = UUID(uuidString: raw),
           sources.contains(where: { $0.id == id }) {
            selected = id
        } else {
            selected = sources[0].id
        }
        return (sources, selected)
    }

    static func save(sources: [TodoSource], selectedID: UUID? = nil) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: key)
        }
        if let selectedID {
            defaults.set(selectedID.uuidString, forKey: selectedKey)
        }
    }

    static func defaultSource() -> TodoSource {
        let url = TodoStore.defaultTodosURL()
        return TodoSource(url: url, title: TodoSource.defaultTitle(for: url))
    }
}
