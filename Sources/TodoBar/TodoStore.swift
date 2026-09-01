import Foundation
import Combine
import AppKit

private let todoBarGitLock = NSLock()

private final class GitOutputBox: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

private enum PullOutcome: Sendable {
    case skipped
    case upToDate
    case pulled
    case failed(String)
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var sections: [TodoSection] = []
    @Published private(set) var itemCount: Int = 0
    @Published private(set) var filePath: URL
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String?
    @Published private(set) var lastLoadedAt: Date?
    /// True only during the brief disk write — never during git.
    @Published private(set) var isBusy = false

    private var doc = TodoDocument()
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var reloadWork: DispatchWorkItem?
    private var suppressWatchUntil: Date = .distantPast
    private var statusToken = 0
    private var pullToken = 0

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
        syncFromRemote()
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
        syncFromRemote()
    }

    /// Pull from upstream (if any), then reload the file. Used on open, tab switch, and Refresh.
    func syncFromRemote() {
        pullToken += 1
        let token = pullToken
        let path = filePath
        // Don't clobber an in-flight mutation status ("Added", "Completed · pushed", …).
        if lastStatus == nil || lastStatus == "Up to date" || lastStatus == "Pulled" || lastStatus == "Pull failed" || lastStatus == "Syncing…" {
            lastStatus = "Syncing…"
        }
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.gitPullSync(file: path)
            await self?.finishPull(token: token, result: result)
        }
    }

    // MARK: - Load

    func reload() {
        do {
            let data = try Data(contentsOf: filePath)
            guard let text = String(data: data, encoding: .utf8) else {
                lastError = "Could not decode file as UTF-8"
                return
            }
            doc = TodoDocument(text: text)
            publish()
            lastError = nil
            lastLoadedAt = Date()
        } catch {
            lastError = error.localizedDescription
            doc = TodoDocument()
            sections = []
            itemCount = 0
        }
    }

    private func publish() {
        let parsed = doc.parse()
        // Always assign new arrays so @Published / observers fire even if counts match.
        sections = parsed
        itemCount = parsed.reduce(0) { $0 + $1.items.filter { !$0.isCompleted }.count }
        objectWillChange.send()
    }

    func openInEditor() {
        NSWorkspace.shared.open(filePath)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([filePath])
    }

    // MARK: - Mutations (document → disk → UI → async git)

    func complete(_ item: TodoItem) {
        guard !isBusy else { return }
        lastError = nil
        do {
            let nowDone = try doc.toggleComplete(
                text: item.text,
                section: item.section,
                lineIndex: item.lineIndex,
                wasCompleted: item.isCompleted
            )
            var files = [filePath]
            if nowDone, let cl = try? appendChangelogIfPresent(completedText: item.text) {
                files.append(cl)
            }
            try save(
                status: nowDone ? "Completed" : "Reopened",
                commitMessage: TodoDocument.commitMessage(
                    prefix: nowDone ? "Complete" : "Reopen",
                    text: item.text
                ),
                files: files
            )
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func addItem(text: String, section sectionTitle: String? = nil) {
        guard !isBusy else { return }
        lastError = nil
        do {
            _ = try doc.addItem(text: text, section: sectionTitle)
            try save(
                status: "Added",
                commitMessage: TodoDocument.commitMessage(prefix: "Add", text: text),
                files: [filePath]
            )
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func updateItem(_ item: TodoItem, text newText: String) {
        guard !isBusy else { return }
        lastError = nil
        do {
            try doc.updateItem(
                text: item.text,
                section: item.section,
                lineIndex: item.lineIndex,
                isCompleted: item.isCompleted,
                newText: newText
            )
            try save(
                status: "Edited",
                commitMessage: TodoDocument.commitMessage(prefix: "Edit", text: newText),
                files: [filePath]
            )
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func deleteItem(_ item: TodoItem) {
        guard !isBusy else { return }
        lastError = nil
        do {
            try doc.deleteItem(
                text: item.text,
                section: item.section,
                lineIndex: item.lineIndex,
                isCompleted: item.isCompleted
            )
            try save(
                status: "Deleted",
                commitMessage: TodoDocument.commitMessage(prefix: "Delete", text: item.text),
                files: [filePath]
            )
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func moveItems(in sectionTitle: String, from source: IndexSet, to destination: Int) {
        guard !isBusy else { return }
        lastError = nil
        do {
            try doc.moveOpenItems(in: sectionTitle, from: source, to: destination)
            try save(
                status: "Reordered",
                commitMessage: "Reorder \(sectionTitle)",
                files: [filePath]
            )
        } catch {
            lastError = error.localizedDescription
            reload()
        }
    }

    func moveOpenItem(_ item: TodoItem, direction: Int) {
        // direction: -1 up, +1 down among open items in section
        guard !item.isCompleted else { return }
        guard let section = sections.first(where: { $0.title == item.section }) else { return }
        let open = section.items.filter { !$0.isCompleted }
        guard let idx = open.firstIndex(where: { $0.id == item.id }) else { return }
        let dest = idx + direction
        guard dest >= 0, dest < open.count else { return }
        // After remove-at-idx, insert-at-dest yields a one-step neighbor swap.
        moveItems(in: item.section, from: IndexSet(integer: idx), to: dest)
    }

    // MARK: - Persist

    private func save(status: String, commitMessage: String, files: [URL]) throws {
        isBusy = true
        defer { isBusy = false }
        suppressWatch(for: 1.5)
        try doc.text.write(to: filePath, atomically: true, encoding: .utf8)
        publish()
        lastLoadedAt = Date()
        lastStatus = status

        statusToken += 1
        let token = statusToken
        let paths = files.map { $0.resolvingSymlinksInPath() }
        let message = commitMessage
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try Self.gitCommitSync(message: message, files: paths)
                await self?.finishGit(
                    token: token,
                    status: status,
                    outcome: result.pushed ? .pushed : .committed,
                    error: result.pushError
                )
            } catch {
                await self?.finishGit(token: token, status: status, outcome: .failed, error: error.localizedDescription)
            }
        }
    }

    private enum GitOutcome {
        case failed
        case committed
        case pushed
    }

    private func finishGit(token: Int, status: String, outcome: GitOutcome, error: String?) {
        guard token == statusToken else { return }
        let allowed: Set = [
            status,
            "\(status) · not committed",
            "\(status) · committed",
            "\(status) · pushed",
        ]
        if allowed.contains(lastStatus ?? "") {
            switch outcome {
            case .failed: lastStatus = "\(status) · not committed"
            case .committed: lastStatus = "\(status) · committed"
            case .pushed: lastStatus = "\(status) · pushed"
            }
        }
        if let error {
            lastError = error
            print("todo-bar git: \(error)")
        }
    }

    private func finishPull(token: Int, result: PullOutcome) {
        guard token == pullToken else { return }
        let canReplaceStatus = lastStatus == nil
            || lastStatus == "Syncing…"
            || lastStatus == "Up to date"
            || lastStatus == "Pulled"
            || lastStatus == "Pull failed"
        switch result {
        case .skipped:
            if lastStatus == "Syncing…" {
                lastStatus = nil
            }
        case .upToDate:
            if canReplaceStatus {
                lastStatus = "Up to date"
            }
        case .pulled:
            suppressWatch(for: 1.5)
            reload()
            if canReplaceStatus {
                lastStatus = "Pulled"
            }
            lastError = nil
        case .failed(let message):
            lastError = message
            print("todo-bar git pull: \(message)")
            if canReplaceStatus {
                lastStatus = "Pull failed"
            }
        }
    }

    // MARK: - Changelog

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
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == dateHeader }) {
            var insertAt = idx + 1
            if insertAt < lines.count, lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            lines.insert(entryLine, at: insertAt)
            var s = lines.joined(separator: "\n")
            if !s.hasSuffix("\n") { s += "\n" }
            return s
        }

        let block = [dateHeader, "", entryLine, ""]
        return (block + lines).joined(separator: "\n")
    }

    // MARK: - Git

    private func gitRoot() throws -> URL {
        let dir = filePath.deletingLastPathComponent().path
        let out = try Self.runGit(arguments: ["-C", dir, "rev-parse", "--show-toplevel"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw NSError(domain: "todo-bar.git", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a git repository"])
        }
        return URL(fileURLWithPath: path)
    }

    private struct GitSyncResult {
        var pushed: Bool
        var pushError: String?
    }

    /// Commit `files`, then `git push` when the branch has an upstream.
    /// Throws only on commit failure. Push failure is returned, not thrown.
    nonisolated private static func gitCommitSync(message: String, files: [URL]) throws -> GitSyncResult {
        todoBarGitLock.lock()
        defer { todoBarGitLock.unlock() }

        guard let first = files.first else { return GitSyncResult(pushed: false, pushError: nil) }
        let dir = first.deletingLastPathComponent().path
        let rootOut = try runGit(arguments: ["-C", dir, "rev-parse", "--show-toplevel"])
        let rootPath = URL(fileURLWithPath: rootOut.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard !rootPath.isEmpty else {
            throw NSError(domain: "todo-bar.git", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a git repository"])
        }

        let relPaths: [String] = try files.map { file in
            let standardized = file.resolvingSymlinksInPath().standardizedFileURL.path
            let inside = standardized == rootPath || standardized.hasPrefix(rootPath + "/")
            guard inside else {
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

        _ = try runGit(arguments: ["-C", rootPath, "add", "--"] + relPaths)
        let status = try runGit(arguments: ["-C", rootPath, "status", "--porcelain", "--"] + relPaths)
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GitSyncResult(pushed: false, pushError: nil)
        }
        _ = try runGit(arguments: ["-C", rootPath, "commit", "-m", message])
        return gitPushIfUpstream(rootPath: rootPath)
    }

    nonisolated private static func hasUpstream(rootPath: String) -> Bool {
        (try? runGit(arguments: [
            "-C", rootPath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}",
        ])) != nil
    }

    nonisolated private static func gitPushIfUpstream(rootPath: String) -> GitSyncResult {
        guard hasUpstream(rootPath: rootPath) else {
            return GitSyncResult(pushed: false, pushError: nil)
        }
        do {
            _ = try runGit(arguments: ["-C", rootPath, "push"], timeoutSeconds: 20)
            return GitSyncResult(pushed: true, pushError: nil)
        } catch {
            return GitSyncResult(pushed: false, pushError: error.localizedDescription)
        }
    }

    /// Pull with rebase + autostash when upstream exists. Never throws — failures are returned.
    nonisolated private static func gitPullSync(file: URL) -> PullOutcome {
        todoBarGitLock.lock()
        defer { todoBarGitLock.unlock() }

        let dir = file.deletingLastPathComponent().path
        let rootOut: String
        do {
            rootOut = try runGit(arguments: ["-C", dir, "rev-parse", "--show-toplevel"])
        } catch {
            return .skipped
        }
        let rootPath = URL(fileURLWithPath: rootOut.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard !rootPath.isEmpty else { return .skipped }
        guard hasUpstream(rootPath: rootPath) else { return .skipped }

        do {
            let out = try runGit(
                arguments: ["-C", rootPath, "pull", "--rebase", "--autostash"],
                timeoutSeconds: 20
            )
            let combined = out.lowercased()
            if combined.contains("already up to date") {
                return .upToDate
            }
            return .pulled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    nonisolated private static func runGit(arguments: [String], timeoutSeconds: Double = 8) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_EDITOR"] = "true"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_LFS_SKIP_PUSH"] = "1"
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        proc.environment = env
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let io = DispatchGroup()
        let box = GitOutputBox()
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            box.stdout = out.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            box.stderr = err.fileHandleForReading.readDataToEndOfFile()
            io.leave()
        }

        try proc.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            proc.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            proc.terminate()
            io.wait()
            throw NSError(domain: "todo-bar.git", code: 124, userInfo: [NSLocalizedDescriptionKey: "git timed out"])
        }
        io.wait()

        let stdout = String(data: box.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: box.stderr, encoding: .utf8) ?? ""
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

extension TodoDocument {
    static func commitMessage(prefix: String, text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let clipped = oneLine.count > 60 ? String(oneLine.prefix(57)) + "..." : oneLine
        return "\(prefix) \(clipped)"
    }
}
