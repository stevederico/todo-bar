import Foundation

// MARK: - Models

struct TodoItem: Identifiable, Hashable {
    let id: String
    let text: String
    let section: String
    /// 0-based index into the raw markdown line array.
    let lineIndex: Int
    let indent: Int
    let isCompleted: Bool
}

struct TodoSection: Identifiable, Hashable {
    let id: String
    let title: String
    var items: [TodoItem]
}

enum TodoDocError: Error, Equatable, LocalizedError {
    case emptyText
    case notFound
    case invalidLine

    var errorDescription: String? {
        switch self {
        case .emptyText: return "Empty to-do text"
        case .notFound: return "Item out of date — refresh and try again"
        case .invalidLine: return "File changed under us — refresh and try again"
        }
    }
}

// MARK: - Pure markdown document (no I/O, no git, no UI)

/// Source of truth for todo markdown mutations. Fully unit-testable.
struct TodoDocument: Equatable {
    var lines: [String]

    init(lines: [String] = []) {
        self.lines = lines
    }

    init(text: String) {
        let raw = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var text: String {
        var body = lines.joined(separator: "\n")
        if !body.hasSuffix("\n") { body += "\n" }
        return body
    }

    // MARK: Parse

    /// Sections in file order. Within each section: open items first, completed last.
    func parse() -> [TodoSection] {
        var currentTitle = "To-Dos"
        var buckets: [(title: String, items: [TodoItem])] = []
        var index: [String: Int] = [:]

        func ensureSection(_ title: String) -> Int {
            if let i = index[title] { return i }
            buckets.append((title, []))
            let i = buckets.count - 1
            index[title] = i
            return i
        }

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isSectionHeader(trimmed) {
                currentTitle = Self.sectionTitle(fromHeader: trimmed)
                _ = ensureSection(currentTitle)
                continue
            }
            guard Self.isTodoLine(line) else { continue }
            let body = Self.todoText(line)
            guard !body.isEmpty else { continue }
            let done = Self.isCompletedTodoLine(line)
            let si = ensureSection(currentTitle)
            buckets[si].items.append(
                TodoItem(
                    id: "\(offset)-\(done ? "x" : "o")-\(body)",
                    text: body,
                    section: currentTitle,
                    lineIndex: offset,
                    indent: Self.leadingWhitespace(line).count,
                    isCompleted: done
                )
            )
        }

        return buckets
            .map { bucket in
                let open = bucket.items.filter { !$0.isCompleted }
                let done = bucket.items.filter(\.isCompleted)
                return (bucket.title, open + done)
            }
            .filter { !$0.1.isEmpty }
            .map { TodoSection(id: $0.0, title: $0.0, items: $0.1) }
    }

    var openCount: Int {
        parse().reduce(0) { $0 + $1.items.filter { !$0.isCompleted }.count }
    }

    var completedCount: Int {
        parse().reduce(0) { $0 + $1.items.filter(\.isCompleted).count }
    }

    /// Section for new items = **visual top of the list**.
    /// Pre-header todos (before first `##`) → `"To-Dos"`. Else first `##` section.
    func defaultAddSection() -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isSectionHeader(trimmed) {
                break // hit a real section before any loose todo
            }
            if Self.isTodoLine(line) {
                return "To-Dos"
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isSectionHeader(trimmed) {
                return Self.sectionTitle(fromHeader: trimmed)
            }
        }
        return "To-Dos"
    }

    // MARK: Mutations

    /// Insert an open todo at the **top** of the open block (first row of that section).
    @discardableResult
    mutating func addItem(text: String, section sectionTitle: String? = nil) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoDocError.emptyText }

        let target = sectionTitle ?? defaultAddSection()
        let newLine = Self.formatTodoLine(indent: "", text: trimmed, completed: false)

        if hasSection(named: target) || (target == "To-Dos" && lines.contains(where: Self.isTodoLine)) {
            let at = insertIndex(sectionTitle: target, completed: false, prepend: true)
            lines.insert(newLine, at: at)
            return at
        }

        // Create section at top of file (after optional H1)
        if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
            lines = ["## \(target)", "", newLine]
            return 2
        }
        var insertAt = 0
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            insertAt = 1
            while insertAt < lines.count, lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
        }
        let block = ["## \(target)", newLine, ""]
        lines.insert(contentsOf: block, at: insertAt)
        return insertAt + 1
    }

    /// Toggle complete: mark done → move that one line to the **end of the file**.
    /// Reopen → put it back at the top of the open list.
    @discardableResult
    mutating func toggleComplete(text: String, section: String, lineIndex hint: Int, wasCompleted: Bool) throws -> Bool {
        guard let idx = resolveLineIndex(text: text, section: section, hint: hint, isCompleted: wasCompleted) else {
            throw TodoDocError.notFound
        }
        let line = lines[idx]
        guard Self.isTodoLine(line), Self.todoText(line) == text else {
            throw TodoDocError.invalidLine
        }
        let indent = Self.leadingWhitespace(line)
        let markCompleted = !Self.isCompletedTodoLine(line)

        lines.remove(at: idx)

        if markCompleted {
            lines.append(Self.formatTodoLine(indent: indent, text: text, completed: true))
        } else {
            let openLine = Self.formatTodoLine(indent: indent, text: text, completed: false)
            let target = defaultAddSection()
            if hasSection(named: target) || (target == "To-Dos" && lines.contains(where: Self.isTodoLine)) {
                let at = insertIndex(sectionTitle: target, completed: false, prepend: true)
                lines.insert(openLine, at: min(at, lines.count))
            } else {
                lines.insert(openLine, at: 0)
            }
        }
        return markCompleted
    }

    mutating func updateItem(text oldText: String, section: String, lineIndex hint: Int, isCompleted: Bool, newText: String) throws {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoDocError.emptyText }
        guard trimmed != oldText else { return }
        guard let idx = resolveLineIndex(text: oldText, section: section, hint: hint, isCompleted: isCompleted) else {
            throw TodoDocError.notFound
        }
        let line = lines[idx]
        guard Self.isTodoLine(line), Self.todoText(line) == oldText else {
            throw TodoDocError.invalidLine
        }
        let indent = Self.leadingWhitespace(line)
        lines[idx] = Self.formatTodoLine(indent: indent, text: trimmed, completed: isCompleted)
    }

    /// Remove the todo line entirely (open or completed).
    mutating func deleteItem(text: String, section: String, lineIndex hint: Int, isCompleted: Bool) throws {
        guard let idx = resolveLineIndex(text: text, section: section, hint: hint, isCompleted: isCompleted) else {
            throw TodoDocError.notFound
        }
        let line = lines[idx]
        guard Self.isTodoLine(line), Self.todoText(line) == text else {
            throw TodoDocError.invalidLine
        }
        lines.remove(at: idx)
        // Drop a blank line that would double-stack after removal
        if idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            let prevBlank = idx > 0 && lines[idx - 1].trimmingCharacters(in: .whitespaces).isEmpty
            if prevBlank {
                lines.remove(at: idx)
            }
        }
    }

    /// Reorder open items only within a section (completed stay at bottom).
    mutating func moveOpenItems(in sectionTitle: String, from source: IndexSet, to destination: Int) throws {
        let section = parse().first { $0.title == sectionTitle }
        guard let section else { throw TodoDocError.notFound }
        var open = section.items.filter { !$0.isCompleted }
        guard !open.isEmpty, source.count > 0 else { return }
        Self.moveItems(&open, from: source, to: destination)

        let slots = section.items.filter { !$0.isCompleted }.map(\.lineIndex).sorted()
        guard slots.count == open.count else { throw TodoDocError.invalidLine }

        for (slot, item) in zip(slots, open) {
            guard slot < lines.count, Self.isTodoLine(lines[slot]) else { throw TodoDocError.invalidLine }
            let indent = Self.leadingWhitespace(lines[slot])
            lines[slot] = Self.formatTodoLine(indent: indent, text: item.text, completed: false)
        }
    }

    /// Foundation-only IndexSet move (SwiftUI's `move(fromOffsets:)` is not available here).
    static func moveItems<T>(_ items: inout [T], from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted().reversed() {
            items.remove(at: index)
        }
        let dest = min(max(destination, 0), items.count)
        items.insert(contentsOf: moving, at: dest)
    }

    // MARK: Line helpers

    static func isSectionHeader(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("##") && !trimmed.hasPrefix("###")
    }

    static func sectionTitle(fromHeader trimmed: String) -> String {
        String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    static func isTodoLine(_ line: String) -> Bool {
        line.range(of: #"^[\t ]*-\s+\S"#, options: .regularExpression) != nil
    }

    static func isCompletedTodoLine(_ line: String) -> Bool {
        line.range(of: #"^[\t ]*-\s+\[[xX]\](\s|$)"#, options: .regularExpression) != nil
    }

    static func todoText(_ line: String) -> String {
        guard let dashRange = line.range(of: #"^[\t ]*-\s+"#, options: .regularExpression) else {
            return ""
        }
        var rest = String(line[dashRange.upperBound...])
        if let box = rest.range(of: #"^\[[xX ]\]\s*"#, options: .regularExpression) {
            rest = String(rest[box.upperBound...])
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    static func formatTodoLine(indent: String, text: String, completed: Bool) -> String {
        completed ? "\(indent)- [x] \(text)" : "\(indent)- \(text)"
    }

    // MARK: Internals

    private func hasSection(named title: String) -> Bool {
        if title == "To-Dos" {
            // Implicit top bucket: todos before first ##, or file with no ## at all
            var sawTodoBeforeHeader = false
            var sawHeader = false
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if Self.isSectionHeader(t) {
                    sawHeader = true
                    break
                }
                if Self.isTodoLine(line) { sawTodoBeforeHeader = true }
            }
            if sawTodoBeforeHeader || !sawHeader { return true }
        }
        return lines.contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return Self.isSectionHeader(t) && Self.sectionTitle(fromHeader: t) == title
        }
    }

    private func resolveLineIndex(text: String, section: String, hint: Int, isCompleted: Bool) -> Int? {
        if hint >= 0, hint < lines.count {
            let line = lines[hint]
            if Self.isTodoLine(line), Self.todoText(line) == text,
               Self.isCompletedTodoLine(line) == isCompleted {
                return hint
            }
        }
        // Prefer same section
        var current = "To-Dos"
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isSectionHeader(trimmed) {
                current = Self.sectionTitle(fromHeader: trimmed)
                continue
            }
            guard current == section, Self.isTodoLine(line), Self.todoText(line) == text else { continue }
            if Self.isCompletedTodoLine(line) == isCompleted { return offset }
        }
        return lines.firstIndex { Self.isTodoLine($0) && Self.todoText($0) == text }
    }

    /// Insert index for a todo in `sectionTitle`.
    /// - open + prepend: first open line (top of list)
    /// - open + append: after last open (before completed)
    /// - completed: after all todos in section
    func insertIndex(sectionTitle: String, completed: Bool, prepend: Bool = false) -> Int {
        var current = "To-Dos"
        var firstOpen: Int?
        var lastOpen: Int?
        var lastTodo: Int?
        var firstCompleted: Int?
        var headerIndex: Int?
        var sectionEnd: Int?
        var sawExplicitHeader = false

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isSectionHeader(trimmed) {
                let title = Self.sectionTitle(fromHeader: trimmed)
                if current == sectionTitle, sectionEnd == nil {
                    sectionEnd = offset
                }
                current = title
                sawExplicitHeader = true
                if current == sectionTitle {
                    headerIndex = offset
                    firstOpen = nil
                    lastOpen = nil
                    lastTodo = nil
                    firstCompleted = nil
                    sectionEnd = nil
                }
                continue
            }

            let inSection: Bool
            if sectionTitle == "To-Dos", !sawExplicitHeader {
                // Implicit top bucket: every line before the first ##
                inSection = true
            } else if current == sectionTitle {
                inSection = true
            } else {
                inSection = false
            }
            guard inSection, Self.isTodoLine(line) else { continue }

            lastTodo = offset
            if Self.isCompletedTodoLine(line) {
                if firstCompleted == nil { firstCompleted = offset }
            } else {
                if firstOpen == nil { firstOpen = offset }
                lastOpen = offset
            }
        }

        if completed {
            if let last = lastTodo { return last + 1 }
            if let header = headerIndex { return header + 1 }
            if let end = sectionEnd { return end }
            return lines.count
        }

        // Open
        if prepend {
            if let first = firstOpen { return first }
            if let firstDone = firstCompleted { return firstDone }
            if let header = headerIndex { return header + 1 }
            // Implicit To-Dos: after H1/blanks, before first ##
            if sectionTitle == "To-Dos" {
                var i = 0
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if Self.isSectionHeader(t) { return i }
                    if t.hasPrefix("#") || t.isEmpty {
                        i += 1
                        continue
                    }
                    return i
                }
            }
            if let end = sectionEnd { return end }
            return 0
        }

        if let last = lastOpen { return last + 1 }
        if let firstDone = firstCompleted { return firstDone }
        if let header = headerIndex { return header + 1 }
        if let end = sectionEnd { return end }
        return lines.count
    }
}
