import Foundation
import AppKit

/// Exhaustive unit + integration smoke for TodoDocument / TodoStore.
@main
struct SmokeMain {
    static var failed = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ok  \(name)")
        } else {
            print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            failed += 1
        }
    }

    static func main() async {
        testParse()
        testAddGoesToTopSectionNotBottom()
        testAddBeforeCompleted()
        testCompleteMovesToBottom()
        testReopenMovesAboveCompleted()
        testUpdatePreservesState()
        testDeleteRemovesLine()
        testReorderOpenOnly()
        testInsertIndexHelpers()
        await testStoreIntegration()
        await testStoreGitPush()
        await testStoreGitPull()

        if failed == 0 {
            print("\nSMOKE PASS")
            exit(0)
        } else {
            print("\nSMOKE FAIL (\(failed) assertion(s))")
            exit(1)
        }
    }

    // MARK: - Pure document tests

    static func testParse() {
        print("== parse ==")
        let doc = TodoDocument(text: """
        # Title

        - open one
        - [x] done one
        ## Section A
        - alpha
        \t- nested
        - [X] done A
        ##video idea
        - clip
        """)
        let sections = doc.parse()
        check("section count", sections.count >= 3)
        let root = sections.first { $0.title == "To-Dos" }
        check("root has 2", root?.items.count == 2)
        check("open before done", root?.items.first?.isCompleted == false && root?.items.last?.isCompleted == true)
        check("strip [x]", root?.items.last?.text == "done one")
        check("## no space", sections.contains { $0.title == "video idea" })
        check("format open", TodoDocument.formatTodoLine(indent: "", text: "x", completed: false) == "- x")
        check("format done", TodoDocument.formatTodoLine(indent: "  ", text: "x", completed: true) == "  - [x] x")
        check("openCount", doc.openCount == 4) // open one, alpha, nested, clip
        check("completedCount", doc.completedCount == 2)
    }

    static func testAddGoesToTopSectionNotBottom() {
        print("== add → top of list ==")
        // Shape like real ~/todos.md: H1, loose todos, then ## sections
        var doc = TodoDocument(text: """
        # To-Do 28

        - first loose
        - second loose
        ## THOUGHTS
        - thought
        ## Archive
        - buried
        - [x] archive done
        """)
        check("default is To-Dos (pre-header)", doc.defaultAddSection() == "To-Dos")
        try! doc.addItem(text: "NEW ITEM")
        let openTop = doc.parse().first { $0.title == "To-Dos" }?.items.filter { !$0.isCompleted }.map(\.text) ?? []
        check("NEW is first open in To-Dos", openTop.first == "NEW ITEM", openTop.description)
        check("NEW before first loose on disk", {
            let lines = doc.lines.filter { TodoDocument.isTodoLine($0) }
            return TodoDocument.todoText(lines[0]) == "NEW ITEM"
        }())
        check("not under Archive", !doc.text.contains("## Archive\n- NEW ITEM"))
    }

    static func testAddBeforeCompleted() {
        print("== add at top of section open block ==")
        var doc = TodoDocument(text: """
        ## S
        - open
        - [x] done1
        - [x] done2
        """)
        try! doc.addItem(text: "fresh", section: "S")
        let lines = doc.lines.filter { TodoDocument.isTodoLine($0) }
        check("line0 fresh (prepend)", !TodoDocument.isCompletedTodoLine(lines[0]) && TodoDocument.todoText(lines[0]) == "fresh")
        check("line1 open", TodoDocument.todoText(lines[1]) == "open")
        check("line2 done", TodoDocument.isCompletedTodoLine(lines[2]))
    }

    static func testCompleteMovesToBottom() {
        print("== complete → append line at EOF ==")
        var doc = TodoDocument(text: """
        # Title
        - top item
        ## THOUGHTS
        - thought
        ## Next
        - other
        ## YC
        - last open
        """)
        let item = doc.parse().flatMap(\.items).first { $0.text == "thought" }!
        _ = try! doc.toggleComplete(
            text: item.text,
            section: item.section,
            lineIndex: item.lineIndex,
            wasCompleted: false
        )
        check("gone from mid-file", !doc.lines.dropLast().contains { TodoDocument.todoText($0) == "thought" })
        check("last line is [x] thought", {
            let last = doc.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }!
            return TodoDocument.isCompletedTodoLine(last) && TodoDocument.todoText(last) == "thought"
        }())
        check("other sections untouched", doc.text.contains("## YC") && doc.text.contains("- last open"))
        check("openCount", doc.openCount == 3)
    }

    static func testReopenMovesAboveCompleted() {
        print("== reopen → top open list ==")
        var doc = TodoDocument(text: """
        ## S
        - live
        - [x] doneA
        - [x] doneB
        """)
        // doneA is mid-list; complete already puts at end — reopen first done at end of file
        doc.lines = [
            "## S",
            "- live",
            "- [x] doneB",
            "- [x] doneA",
        ]
        let item = doc.parse().flatMap(\.items).first { $0.text == "doneA" && $0.isCompleted }!
        _ = try! doc.toggleComplete(
            text: item.text,
            section: item.section,
            lineIndex: item.lineIndex,
            wasCompleted: true
        )
        check("doneA not completed", doc.parse().flatMap(\.items).contains { $0.text == "doneA" && !$0.isCompleted })
        let openTop = doc.parse().flatMap(\.items).filter { !$0.isCompleted }.map(\.text)
        check("doneA at top of open", openTop.first == "doneA", openTop.description)
        check("doneB still completed", doc.text.contains("- [x] doneB"))
    }

    static func testUpdatePreservesState() {
        print("== edit ==")
        var doc = TodoDocument(text: """
        ## S
        - hello
        - [x] bye
        """)
        let open = doc.parse().flatMap(\.items).first { $0.text == "hello" }!
        try! doc.updateItem(text: "hello", section: "S", lineIndex: open.lineIndex, isCompleted: false, newText: "hello world")
        check("edited text", doc.text.contains("- hello world"))
        check("still open", doc.parse().flatMap(\.items).contains { $0.text == "hello world" && !$0.isCompleted })

        let done = doc.parse().flatMap(\.items).first { $0.text == "bye" }!
        try! doc.updateItem(text: "bye", section: "S", lineIndex: done.lineIndex, isCompleted: true, newText: "bye now")
        check("edited done keeps [x]", doc.lines.contains { $0.contains("[x]") && $0.contains("bye now") })
    }

    static func testDeleteRemovesLine() {
        print("== delete ==")
        var doc = TodoDocument(text: """
        ## S
        - keep
        - drop me
        - [x] done
        """)
        let drop = doc.parse().flatMap(\.items).first { $0.text == "drop me" }!
        try! doc.deleteItem(text: drop.text, section: drop.section, lineIndex: drop.lineIndex, isCompleted: false)
        check("open gone", !doc.text.contains("drop me"))
        check("keep remains", doc.text.contains("- keep"))
        check("done remains", doc.text.contains("- [x] done"))
        check("openCount 1", doc.openCount == 1)

        let done = doc.parse().flatMap(\.items).first { $0.text == "done" && $0.isCompleted }!
        try! doc.deleteItem(text: done.text, section: done.section, lineIndex: done.lineIndex, isCompleted: true)
        check("done gone", !doc.text.contains("[x] done"))
        check("completedCount 0", doc.completedCount == 0)
    }

    static func testReorderOpenOnly() {
        print("== reorder ==")
        var doc = TodoDocument(text: """
        ## S
        - a
        - b
        - c
        - [x] z
        """)
        try! doc.moveOpenItems(in: "S", from: IndexSet(integer: 0), to: 3) // move a to end of open
        let open = doc.parse().first { $0.title == "S" }!.items.filter { !$0.isCompleted }.map(\.text)
        check("a moved to end of open", open == ["b", "c", "a"], open.description)
        check("z still completed last", doc.parse().first { $0.title == "S" }!.items.last?.text == "z")
    }

    static func testInsertIndexHelpers() {
        print("== insertIndex ==")
        let doc = TodoDocument(text: """
        - loose
        ## Mid
        - m1
        - [x] md
        ## End
        - e1
        """)
        check("open Mid after m1", doc.insertIndex(sectionTitle: "Mid", completed: false) == 3) // after m1 (line 2), before [x]
        // lines: 0 loose, 1 ## Mid, 2 m1, 3 [x] md, 4 ## End, 5 e1
        // After remove... just check relative
        var d = doc
        try! d.addItem(text: "x", section: "Mid")
        let midTodos = sectionTodoLines(d, "Mid").map(TodoDocument.todoText)
        check("Mid prepend open then done", midTodos == ["x", "m1", "md"], midTodos.description)
    }

    static func sectionTodoLines(_ doc: TodoDocument, _ section: String) -> [String] {
        var current = "To-Dos"
        var out: [String] = []
        for line in doc.lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if TodoDocument.isSectionHeader(t) {
                current = TodoDocument.sectionTitle(fromHeader: t)
                continue
            }
            if current == section, TodoDocument.isTodoLine(line) {
                out.append(line)
            }
        }
        return out
    }

    // MARK: - Store integration

    static func testStoreIntegration() async {
        print("== store integration ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-bar-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let md = tmp.appendingPathComponent("todos.md")
        try! """
        ## Inbox
        - first
        - second
        ## Later
        - later item
        - [x] old
        """.write(to: md, atomically: true, encoding: .utf8)

        func sh(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = tmp
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try! p.run()
            p.waitUntilExit()
        }
        sh(["init"])
        sh(["config", "user.email", "smoke@todo-bar.test"])
        sh(["config", "user.name", "Smoke"])
        sh(["add", "."])
        sh(["commit", "-m", "init"])

        let store = await MainActor.run { TodoStore(filePath: md) }
        check("loaded", await MainActor.run { store.itemCount } == 3)

        let t0 = Date()
        await MainActor.run { store.addItem(text: "BRAND NEW") }
        check("add unlocks", await MainActor.run { !store.isBusy })
        check("add fast", Date().timeIntervalSince(t0) < 0.5)
        check("count +1", await MainActor.run { store.itemCount } == 4)

        let disk = try! String(contentsOf: md, encoding: .utf8)
        let newRange = disk.range(of: "- BRAND NEW")!
        let laterRange = disk.range(of: "## Later")!
        let oldDone = disk.range(of: "- [x] old")!
        check("added under Inbox not Later", newRange.upperBound < laterRange.lowerBound)
        // Prepend: NEW is first todo under Inbox
        let inboxBody = disk.components(separatedBy: "## Later")[0]
        let firstTodo = inboxBody.split(separator: "\n").map(String.init).first { TodoDocument.isTodoLine($0) }
        check("BRAND NEW is first todo in Inbox", firstTodo.map(TodoDocument.todoText) == "BRAND NEW", firstTodo ?? "nil")
        check("not after [x] old", newRange.lowerBound < oldDone.lowerBound)

        // Complete first open in Inbox
        let target = await MainActor.run {
            store.sections.flatMap(\.items).first { $0.text == "BRAND NEW" && !$0.isCompleted }
        }
        check("found new item", target != nil)
        if let target {
            await MainActor.run { store.complete(target) }
            check("complete unlocks", await MainActor.run { !store.isBusy })
            check("open count -1", await MainActor.run { store.itemCount } == 3)
            let after = try! String(contentsOf: md, encoding: .utf8)
            check("disk has [x]", after.contains("- [x] BRAND NEW"))
            check("line is last on disk", {
                let last = after.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return last.map { TodoDocument.todoText($0) == "BRAND NEW" && TodoDocument.isCompletedTodoLine($0) } ?? false
            }())
        }

        let status = await waitGitStatus(store)
        check("idle after git", await MainActor.run { !store.isBusy })
        check(
            "no-remote commits, does not push",
            isCommittedOnly(status),
            status ?? "nil"
        )
        check("no git error", await MainActor.run { store.lastError == nil }, await MainActor.run { store.lastError ?? "" })
    }

    static func testStoreGitPush() async {
        print("== store git push ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-bar-smoke-push-\(UUID().uuidString)", isDirectory: true)
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        let bare = tmp.appendingPathComponent("remote.git")
        try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let md = work.appendingPathComponent("todos.md")
        try! "# To-Do\n\n- existing\n".write(to: md, atomically: true, encoding: .utf8)

        func git(_ dir: URL, _ args: [String], capture: Bool = false) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            let out = Pipe()
            p.standardOutput = capture ? out : FileHandle.nullDevice
            p.standardError = capture ? out : FileHandle.nullDevice
            try! p.run()
            p.waitUntilExit()
            let text = capture
                ? (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                : ""
            return (p.terminationStatus, text)
        }

        _ = git(work, ["init", "-b", "master"])
        _ = git(work, ["config", "user.email", "smoke@todo-bar.test"])
        _ = git(work, ["config", "user.name", "Smoke"])
        _ = git(work, ["add", "."])
        _ = git(work, ["commit", "-m", "init"])
        _ = git(tmp, ["init", "--bare", "-b", "master", bare.path])
        _ = git(work, ["remote", "add", "origin", bare.path])
        let pushedInit = git(work, ["push", "-u", "origin", "master"], capture: true)
        check("upstream set", pushedInit.0 == 0, pushedInit.1)

        let store = await MainActor.run { TodoStore(filePath: md) }
        await MainActor.run { store.addItem(text: "PUSHED ITEM") }
        let status = await waitGitStatus(store, timeout: 25)
        check("status pushed", isPushed(status), status ?? "nil")
        check("no push error", await MainActor.run { store.lastError == nil }, await MainActor.run { store.lastError ?? "" })

        let log = git(bare, ["log", "-1", "--pretty=%s"], capture: true)
        check("remote has commit", log.1.trimmingCharacters(in: .whitespacesAndNewlines) == "Add PUSHED ITEM", log.1)
    }

    static func testStoreGitPull() async {
        print("== store git pull ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-bar-smoke-pull-\(UUID().uuidString)", isDirectory: true)
        let remoteWork = tmp.appendingPathComponent("remote-work", isDirectory: true)
        let local = tmp.appendingPathComponent("local", isDirectory: true)
        let bare = tmp.appendingPathComponent("remote.git")
        try! FileManager.default.createDirectory(at: remoteWork, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func git(_ dir: URL, _ args: [String], capture: Bool = false) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            let out = Pipe()
            p.standardOutput = capture ? out : FileHandle.nullDevice
            p.standardError = capture ? out : FileHandle.nullDevice
            try! p.run()
            p.waitUntilExit()
            let text = capture
                ? (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                : ""
            return (p.terminationStatus, text)
        }

        try! "# To-Do\n\n- seed\n".write(
            to: remoteWork.appendingPathComponent("todos.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = git(remoteWork, ["init", "-b", "master"])
        _ = git(remoteWork, ["config", "user.email", "smoke@todo-bar.test"])
        _ = git(remoteWork, ["config", "user.name", "Smoke"])
        _ = git(remoteWork, ["add", "."])
        _ = git(remoteWork, ["commit", "-m", "init"])
        _ = git(tmp, ["init", "--bare", "-b", "master", bare.path])
        _ = git(remoteWork, ["remote", "add", "origin", bare.path])
        let pushed = git(remoteWork, ["push", "-u", "origin", "master"], capture: true)
        check("bare ready", pushed.0 == 0, pushed.1)

        let clone = git(tmp, ["clone", bare.path, local.path], capture: true)
        check("cloned", clone.0 == 0, clone.1)
        _ = git(local, ["config", "user.email", "smoke@todo-bar.test"])
        _ = git(local, ["config", "user.name", "Smoke"])

        // Advance remote after clone so local is behind
        let remoteMd = remoteWork.appendingPathComponent("todos.md")
        try! "# To-Do\n\n- from remote\n- seed\n".write(to: remoteMd, atomically: true, encoding: .utf8)
        _ = git(remoteWork, ["add", "."])
        _ = git(remoteWork, ["commit", "-m", "remote update"])
        _ = git(remoteWork, ["push"], capture: true)

        let localMd = local.appendingPathComponent("todos.md")
        let before = try! String(contentsOf: localMd, encoding: .utf8)
        check("local still seed-only", !before.contains("from remote"), before)

        let store = await MainActor.run { TodoStore(filePath: localMd) }
        let pulled = await waitPullStatus(store, timeout: 25)
        check("status pulled", pulled == "Pulled", pulled ?? "nil")
        check("no pull error", await MainActor.run { store.lastError == nil }, await MainActor.run { store.lastError ?? "" })
        let after = try! String(contentsOf: localMd, encoding: .utf8)
        check("disk has remote item", after.contains("from remote"), after)
        check("ui shows remote item", await MainActor.run {
            store.sections.flatMap(\.items).contains { $0.text == "from remote" }
        })
    }

    static func waitGitStatus(_ store: TodoStore, timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await MainActor.run { store.lastStatus }
            if isCommittedOnly(status) || isPushed(status) || isNotCommitted(status) {
                return status
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run { store.lastStatus }
    }

    static func waitPullStatus(_ store: TodoStore, timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await MainActor.run { store.lastStatus }
            if status == "Pulled" || status == "Up to date" || status == "Pull failed" {
                return status
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run { store.lastStatus }
    }

    static func isPushed(_ status: String?) -> Bool {
        status?.hasSuffix(" · pushed") == true
    }

    static func isCommittedOnly(_ status: String?) -> Bool {
        status?.hasSuffix(" · committed") == true
    }

    static func isNotCommitted(_ status: String?) -> Bool {
        status?.hasSuffix(" · not committed") == true
    }
}
