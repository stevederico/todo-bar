import Foundation
import Combine
import AppKit

struct TodoItem: Identifiable, Hashable {
    let id: String
    let text: String
    let section: String
    /// 0-based index into the raw markdown line array.
    let lineIndex: Int
    let indent: Int
    /// True when the line is `- [x] …` / `- [X] …`.
    let isCompleted: Bool
}

struct TodoSection: Identifiable, Hashable {
    let id: String
    let title: String
    var items: [TodoItem]
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var sections: [TodoSection] = []
    @Published private(set) var itemCount: Int = 0
    @Published private(set) var filePath: URL
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var isBusy = false

    /// Full file lines (source of truth for writes).
    private var lines: [String] = []
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var reloadWork: DispatchWorkItem?
    private var suppressWatchUntil: Date = .distantPast

    /// Prefer `~/todos.md`, then `~/Documents/todos.md`.
    nonisolated static func defaultTodosURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("todos.md"),
            home.appendingPathComponent("Documents/todos.md"),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url.resolvingSymlinksInPath()
            }
        }
        return candidates[0]
    }

    init(filePath: URL = TodoStore.defaultTodosURL()) {
        self.filePath = filePath.resolvingSymlinksInPath()
        reload()
        startWatching()
    }

    deinit {
        source?.cancel()
        source = nil
        if directoryFD >= 0 {
            close(directoryFD)
            directoryFD = -1
        }
        reloadWork?.cancel()
        reloadWork = nil
    }

    /// Switch the active markdown file (tab change).
    func setFile(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved != filePath else {
            reload()
            return
        }
        stopWatching()
        filePath = resolved
        lastError = nil
        lastStatus = nil
        reload()
        startWatching()
    }

    // MARK: - Load

    func reload() {
        do {
            let data = try Data(contentsOf: filePath)
            guard let text = String(data: data, encoding: .utf8) else {
                lastError = "Could not decode file as UTF-8"
                return
            }
            apply(text: text)
            lastError = nil
            lastLoadedAt = Date()
        } catch {
            lastError = error.localizedDescription
            sections = []
            itemCount = 0
            lines = []
        }
    }

    private func apply(text: String) {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = Self.parse(lines: lines)
        sections = parsed
        // Badge = open only
        itemCount = parsed.reduce(0) { $0 + $1.items.filter { !$0.isCompleted }.count }
    }

    func openInEditor() {
        NSWorkspace.shared.open(filePath)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([filePath])
    }

    // MARK: - Complete

    /// Mark open item done (`- [x]`), move to bottom of its section; optionally log CHANGELOG; git commit.
    /// If already completed, uncomplete (`- item`) and move above completed block.
    /// File write always wins — git is best-effort so a commit failure can't undo complete.
    func complete(_ item: TodoItem) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        lastStatus = nil

        guard let lineIndex = resolveLineIndex(for: item) else {
            lastError = "Item out of date — refresh and try again"
            isBusy = false
            reload()
            return
        }

        let line = lines[lineIndex]
        let indent = Self.leadingWhitespace(line)
        let wasCompleted = Self.isCompletedTodoLine(line)
        let markCompleted = !wasCompleted
        let newLine = Self.formatTodoLine(indent: indent, text: item.text, completed: markCompleted)

        lines.remove(at: lineIndex)
        let insertAt = todoInsertIndex(
            sectionTitle: item.section,
            completed: markCompleted,
            preferEnd: true
        )
        lines.insert(newLine, at: min(max(insertAt, 0), lines.count))

        do {
            try writeFile()
        } catch {
            lastError = error.localizedDescription
            isBusy = false
            reload()
            return
        }

        // Refresh UI from the lines we just wrote (don't wait on git).
        reparseFromLines()
        isBusy = false
        lastStatus = markCompleted ? "Completed" : "Reopened"

        var commitPaths = [filePath]
        if markCompleted {
            do {
                if let cl = try appendChangelogIfPresent(completedText: item.text) {
                    commitPaths.append(cl)
                }
            } catch {
                // Changelog is optional; keep the completed todo.
            }
        }
        let prefix = markCompleted ? "Complete" : "Reopen"
        let msg = Self.commitMessage(prefix: prefix, text: item.text)
        do {
            try gitCommit(message: msg, files: commitPaths)
            lastStatus = markCompleted ? "Completed · committed" : "Reopened · committed"
        } catch {
            // Not a git repo / commit hook noise — file already saved.
            lastStatus = markCompleted ? "Completed · not committed" : "Reopened · not committed"
        }
    }

    /// Match by lineIndex + text, else scan for the same open/completed line text.
    private func resolveLineIndex(for item: TodoItem) -> Int? {
        if item.lineIndex >= 0, item.lineIndex < lines.count {
            let line = lines[item.lineIndex]
            if Self.isTodoLine(line), Self.todoText(line) == item.text {
                return item.lineIndex
            }
        }
        for (offset, line) in lines.enumerated() {
            guard Self.isTodoLine(line), Self.todoText(line) == item.text else { continue }
            if Self.isCompletedTodoLine(line) == item.isCompleted {
                return offset
            }
        }
        return lines.firstIndex { Self.isTodoLine($0) && Self.todoText($0) == item.text }
    }

    private func reparseFromLines() {
        let parsed = Self.parse(lines: lines)
        sections = parsed
        itemCount = parsed.reduce(0) { $0 + $1.items.filter { !$0.isCompleted }.count }
        lastLoadedAt = Date()
    }

    /// Insert index for a todo in `sectionTitle`: open items before completed; completed at end of section.
    /// Default section `"To-Dos"` also owns dash-lines before the first `##` header.
    private func todoInsertIndex(sectionTitle: String, completed: Bool, preferEnd: Bool) -> Int {
        var current = "To-Dos"
        var firstTodo: Int?
        var lastOpen: Int?
        var lastTodo: Int?
        var firstCompleted: Int?
        var headerIndex: Int?
        var sectionEnd: Int? // first line after this section (next ##)

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if current == sectionTitle, sectionEnd == nil, offset > (headerIndex ?? -1) {
                    // Leaving the target section
                    if headerIndex != nil || sectionTitle == "To-Dos" {
                        sectionEnd = offset
                    }
                }
                current = title
                if current == sectionTitle {
                    headerIndex = offset
                    firstTodo = nil
                    lastOpen = nil
                    lastTodo = nil
                    firstCompleted = nil
                    sectionEnd = nil
                }
                continue
            }
            guard current == sectionTitle, Self.isTodoLine(line) else { continue }
            if firstTodo == nil { firstTodo = offset }
            lastTodo = offset
            if Self.isCompletedTodoLine(line) {
                if firstCompleted == nil { firstCompleted = offset }
            } else {
                lastOpen = offset
            }
        }

        if completed {
            if let last = lastTodo { return last + 1 }
            if let header = headerIndex { return header + 1 }
            // Pre-header "To-Dos": before first ##, or end of file
            if sectionTitle == "To-Dos", let end = sectionEnd { return end }
            return lines.count
        }

        // Open: after last open, or before first completed, or after header
        if let last = lastOpen { return last + 1 }
        if let firstDone = firstCompleted { return firstDone }
        if let last = lastTodo { return last + 1 }
        if let header = headerIndex { return header + 1 }
        if sectionTitle == "To-Dos", let end = sectionEnd { return end }
        if preferEnd { return lines.count }
        return firstTodo ?? lines.count
    }

    // MARK: - Add

    /// Append an open item to a section (default: last section, or "To-Dos").
    func addItem(text: String, section sectionTitle: String? = nil) {
        guard !isBusy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isBusy = true
        lastError = nil
        lastStatus = nil
        defer { isBusy = false }

        let target = sectionTitle
            ?? sections.last?.title
            ?? "To-Dos"
        let newLine = "- \(trimmed)"

        let hasHeader = lines.contains {
            $0.trimmingCharacters(in: .whitespaces) == "## \(target)"
        }
        let hasSection = sections.contains(where: { $0.title == target }) || hasHeader
        // Default bucket with no `##` — still append among existing dash lines
        let hasLooseTodos = target == "To-Dos" && lines.contains(where: Self.isTodoLine)

        if hasSection || hasLooseTodos {
            let insertAt = todoInsertIndex(sectionTitle: target, completed: false, preferEnd: true)
            lines.insert(newLine, at: min(max(insertAt, 0), lines.count))
        } else {
            // Empty / no matching section — ensure header then item
            if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
                lines = ["## \(target)", "", newLine]
            } else {
                if !lines.isEmpty, !lines[lines.count - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines.append("## \(target)")
                lines.append(newLine)
            }
        }

        do {
            try writeFile()
            let msg = Self.commitMessage(prefix: "Add", text: trimmed)
            try gitCommit(message: msg, files: [filePath])
            lastStatus = "Added · committed"
            reload()
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    // MARK: - Edit

    /// Rewrite the text of an open item (indent preserved).
    func updateItem(_ item: TodoItem, text newText: String) {
        guard !isBusy else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != item.text else { return }

        isBusy = true
        lastError = nil
        lastStatus = nil
        defer { isBusy = false }

        guard item.lineIndex >= 0, item.lineIndex < lines.count else {
            lastError = "Item out of date — refresh and try again"
            reload()
            return
        }

        let line = lines[item.lineIndex]
        guard Self.isTodoLine(line), Self.todoText(line) == item.text else {
            lastError = "File changed under us — refresh and try again"
            reload()
            return
        }

        let indent = Self.leadingWhitespace(line)
        lines[item.lineIndex] = Self.formatTodoLine(indent: indent, text: trimmed, completed: item.isCompleted)

        do {
            try writeFile()
            let msg = Self.commitMessage(prefix: "Edit", text: trimmed)
            try gitCommit(message: msg, files: [filePath])
            lastStatus = "Edited · committed"
            reload()
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    // MARK: - Reorder

    /// Reorder **open** items only (completed stay at section bottom).
    func moveItems(in sectionTitle: String, from source: IndexSet, to destination: Int) {
        guard !isBusy else { return }
        guard let section = sections.first(where: { $0.title == sectionTitle }) else { return }
        guard source.count > 0 else { return }

        isBusy = true
        lastError = nil
        lastStatus = nil
        defer { isBusy = false }

        var openItems = section.items.filter { !$0.isCompleted }
        guard !openItems.isEmpty else { return }
        openItems.move(fromOffsets: source, toOffset: destination)

        let slots = section.items.filter { !$0.isCompleted }.map(\.lineIndex).sorted()
        guard slots.count == openItems.count else {
            lastError = "Reorder failed — refresh"
            return
        }

        for (slot, item) in zip(slots, openItems) {
            guard slot < lines.count, Self.isTodoLine(lines[slot]) else {
                lastError = "Reorder failed — file changed"
                reload()
                return
            }
            let indent = Self.leadingWhitespace(lines[slot])
            lines[slot] = Self.formatTodoLine(indent: indent, text: item.text, completed: false)
        }

        do {
            try writeFile()
            let msg = "Reorder \(sectionTitle)"
            try gitCommit(message: msg, files: [filePath])
            lastStatus = "Reordered · committed"
            reload()
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    // MARK: - Parse

    static func parse(lines: [String]) -> [TodoSection] {
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

            if trimmed.hasPrefix("##") {
                currentTitle = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                _ = ensureSection(currentTitle)
                continue
            }

            guard isTodoLine(line) else { continue }
            let text = todoText(line)
            guard !text.isEmpty else { continue }

            let indent = leadingWhitespace(line).count
            let done = isCompletedTodoLine(line)
            let sectionIndex = ensureSection(currentTitle)
            let item = TodoItem(
                id: "\(offset)-\(done ? "x" : "o")-\(text)",
                text: text,
                section: currentTitle,
                lineIndex: offset,
                indent: indent,
                isCompleted: done
            )
            buckets[sectionIndex].items.append(item)
        }

        // Open first, completed last (stable within each group)
        return buckets
            .map { bucket in
                let open = bucket.items.filter { !$0.isCompleted }
                let done = bucket.items.filter(\.isCompleted)
                return (bucket.title, open + done)
            }
            .filter { !$0.1.isEmpty }
            .map { TodoSection(id: $0.0, title: $0.0, items: $0.1) }
    }

    static func isTodoLine(_ line: String) -> Bool {
        line.range(of: #"^[\t ]*-\s+\S"#, options: .regularExpression) != nil
    }

    /// `- [x] …` / `- [X] …` (GFM done).
    static func isCompletedTodoLine(_ line: String) -> Bool {
        line.range(of: #"^[\t ]*-\s+\[[xX]\](\s|$)"#, options: .regularExpression) != nil
    }

    /// Body after `- ` and optional `[x]` / `[ ]` checkbox.
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

    // MARK: - Write

    private func writeFile() throws {
        suppressWatch(for: 1.5)
        let body = lines.joined(separator: "\n")
        let out = body.hasSuffix("\n") ? body : body + "\n"
        try out.write(to: filePath, atomically: true, encoding: .utf8)
    }

    /// Only touch CHANGELOG if one already exists next to the file or at git root.
    @discardableResult
    private func appendChangelogIfPresent(completedText: String) throws -> URL? {
        guard let changelogURL = resolveExistingChangelog() else { return nil }
        suppressWatch(for: 1.5)
        let today = Self.todayHeader()
        let entry = "  \(completedText)"
        let existing = try String(contentsOf: changelogURL, encoding: .utf8)
        let updated = Self.insertChangelogEntry(into: existing, dateHeader: today, entryLine: entry)
        try updated.write(to: changelogURL, atomically: true, encoding: .utf8)
        return changelogURL
    }

    private func resolveExistingChangelog() -> URL? {
        let beside = filePath.deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        if FileManager.default.fileExists(atPath: beside.path) {
            return beside
        }
        if let root = try? gitRoot() {
            let atRoot = root.appendingPathComponent("CHANGELOG.md")
            if FileManager.default.fileExists(atPath: atRoot.path) {
                return atRoot
            }
        }
        return nil
    }

    static func todayHeader(date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .year], from: date)
        let yy = (c.year ?? 0) % 100
        return String(format: "%02d/%02d/%02d", c.month ?? 0, c.day ?? 0, yy)
    }

    static func insertChangelogEntry(into content: String, dateHeader: String, entryLine: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == dateHeader }) {
            var insertAt = idx + 1
            if insertAt < lines.count, lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            lines.insert(entryLine, at: insertAt)
            return joinChangelog(lines)
        }

        let block = [dateHeader, "", entryLine, ""]
        return (block + lines).joined(separator: "\n")
    }

    private static func joinChangelog(_ lines: [String]) -> String {
        var s = lines.joined(separator: "\n")
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    static func commitMessage(prefix: String, text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let clipped = oneLine.count > 60 ? String(oneLine.prefix(57)) + "..." : oneLine
        return "\(prefix) \(clipped)"
    }

    // MARK: - Git

    private func gitRoot() throws -> URL {
        let dir = filePath.deletingLastPathComponent().path
        let out = try run(
            executable: "/usr/bin/git",
            arguments: ["-C", dir, "rev-parse", "--show-toplevel"]
        )
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw NSError(
                domain: "todo-bar.git",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Not a git repository"]
            )
        }
        return URL(fileURLWithPath: path)
    }

    private func gitCommit(message: String, files: [URL]) throws {
        let root = try gitRoot()
        let rootPath = root.path

        let relPaths: [String] = try files.map { file in
            let standardized = file.resolvingSymlinksInPath().path
            guard standardized.hasPrefix(rootPath) else {
                throw NSError(
                    domain: "todo-bar.git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "File outside git root: \(file.lastPathComponent)"]
                )
            }
            var rel = String(standardized.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            return rel.isEmpty ? file.lastPathComponent : rel
        }

        _ = try run(executable: "/usr/bin/git", arguments: ["-C", rootPath, "add", "--"] + relPaths)

        let status = try run(
            executable: "/usr/bin/git",
            arguments: ["-C", rootPath, "status", "--porcelain", "--"] + relPaths
        )
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        _ = try run(
            executable: "/usr/bin/git",
            arguments: ["-C", rootPath, "commit", "-m", message]
        )
    }

    @discardableResult
    private func run(executable: String, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "todo-bar.git",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "git failed (\(proc.terminationStatus))" : detail]
            )
        }
        return stdout
    }

    // MARK: - File watch

    private func suppressWatch(for seconds: TimeInterval) {
        suppressWatchUntil = Date().addingTimeInterval(seconds)
    }

    private func startWatching() {
        stopWatching()
        let dir = filePath.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if Date() < self.suppressWatchUntil { return }
            self.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        directoryFD = -1
        reloadWork?.cancel()
        reloadWork = nil
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Date() < self.suppressWatchUntil { return }
            self.reload()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
