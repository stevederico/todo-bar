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
        print("== complete → ## Completed at EOF ==")
        var doc = TodoDocument(text: """
        ## S
        - one
        - two
        - three
        ## Next
        - other
        """)
        let item = doc.parse().flatMap(\.items).first { $0.text == "one" }!
        _ = try! doc.toggleComplete(
            text: item.text,
            section: item.section,
            lineIndex: item.lineIndex,
            wasCompleted: false
        )
        check("has ## Completed", doc.lines.contains { $0.trimmingCharacters(in: .whitespaces) == "## Completed" })
        check("one not in S", !sectionTodoLines(doc, "S").contains { TodoDocument.todoText($0) == "one" })
        check("other untouched", doc.text.contains("- other"))
        check("openCount 3", doc.openCount == 3)
        // Completed section is last, item is last todo line
        let lastHeader = doc.lines.lastIndex { TodoDocument.isSectionHeader($0.trimmingCharacters(in: .whitespaces)) }!
        check("Completed is last header", TodoDocument.sectionTitle(fromHeader: doc.lines[lastHeader].trimmingCharacters(in: .whitespaces)) == "Completed")
        let lastTodo = doc.lines.last { TodoDocument.isTodoLine($0) }!
        check("one is last todo in file", TodoDocument.todoText(lastTodo) == "one" && TodoDocument.isCompletedTodoLine(lastTodo))
        // Second complete stacks under Completed
        let two = doc.parse().flatMap(\.items).first { $0.text == "two" }!
        _ = try! doc.toggleComplete(text: two.text, section: two.section, lineIndex: two.lineIndex, wasCompleted: false)
        let completedLines = sectionTodoLines(doc, "Completed").map(TodoDocument.todoText)
        check("both under Completed", completedLines == ["one", "two"], completedLines.description)
    }

    static func testReopenMovesAboveCompleted() {
        print("== reopen → top open list ==")
        var doc = TodoDocument(text: """
        ## S
        - live
        ## Completed
        - [x] doneA
        - [x] doneB
        """)
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
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check("idle after git", await MainActor.run { !store.isBusy })
    }
}
