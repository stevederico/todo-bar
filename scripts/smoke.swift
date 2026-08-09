import Foundation
import AppKit

/// Headless smoke tests for TodoStore (parse + file mutations + no main-thread hang).
/// Build: see scripts/smoke.sh

@main
struct SmokeMain {
    static func main() async {
        var failed = 0
        func check(_ name: String, _ ok: @autoclosure () -> Bool) {
            if ok() {
                print("  ok  \(name)")
            } else {
                print("  FAIL \(name)")
                failed += 1
            }
        }

        print("== parse ==")
        let lines = [
            "# Title",
            "",
            "- open one",
            "- [x] done one",
            "## Section A",
            "- alpha",
            "\t- nested",
            "- [X] done A",
            "##video idea",
            "- clip",
        ]
        let sections = TodoStore.parse(lines: lines)
        check("has sections", sections.count >= 2)
        let root = sections.first { $0.title == "To-Dos" }
        check("root open+done", root?.items.count == 2)
        check("root open first", root?.items.first?.isCompleted == false)
        check("root done last", root?.items.last?.isCompleted == true)
        check("checkbox stripped", root?.items.last?.text == "done one")
        check("## without space", sections.contains { $0.title == "video idea" })
        check("format open", TodoStore.formatTodoLine(indent: "", text: "x", completed: false) == "- x")
        check("format done", TodoStore.formatTodoLine(indent: "  ", text: "x", completed: true) == "  - [x] x")
        check("todoText strips [x]", TodoStore.todoText("- [x] hi") == "hi")
        check("isCompleted", TodoStore.isCompletedTodoLine("- [x] hi"))
        check("not completed open", !TodoStore.isCompletedTodoLine("- hi"))

        print("== store mutations (temp git repo) ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-bar-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let md = tmp.appendingPathComponent("todos.md")
        try! """
        ## Inbox
        - first
        - second
        """.write(to: md, atomically: true, encoding: .utf8)

        // init git so commit path is exercised
        func sh(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = tmp
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try! p.run()
            p.waitUntilExit()
            precondition(p.terminationStatus == 0, "git \(args) failed")
        }
        sh(["init"])
        sh(["config", "user.email", "smoke@todo-bar.test"])
        sh(["config", "user.name", "Smoke"])
        sh(["add", "todos.md"])
        sh(["commit", "-m", "init"])

        let store = await MainActor.run { TodoStore(filePath: md) }
        let openCount: Int = await MainActor.run { store.itemCount }
        check("loaded open count", openCount == 2)

        // Add
        let t0 = Date()
        await MainActor.run { store.addItem(text: "smoke add item") }
        let addBusy: Bool = await MainActor.run { store.isBusy }
        let addElapsed = Date().timeIntervalSince(t0)
        check("add unlocks immediately", !addBusy)
        check("add returns < 0.5s (no git block)", addElapsed < 0.5)
        let afterAdd: Int = await MainActor.run { store.itemCount }
        check("add increases count", afterAdd == 3)
        let diskAfterAdd = try! String(contentsOf: md, encoding: .utf8)
        check("add wrote disk", diskAfterAdd.contains("- smoke add item"))

        // Complete
        let item: TodoItem? = await MainActor.run {
            store.sections.flatMap(\.items).first { $0.text == "smoke add item" && !$0.isCompleted }
        }
        check("find added item", item != nil)
        if let item {
            let t1 = Date()
            await MainActor.run { store.complete(item) }
            let completeBusy: Bool = await MainActor.run { store.isBusy }
            check("complete unlocks immediately", !completeBusy)
            check("complete returns < 0.5s", Date().timeIntervalSince(t1) < 0.5)
            let afterComplete: Int = await MainActor.run { store.itemCount }
            check("complete drops open count", afterComplete == 2)
            let disk = try! String(contentsOf: md, encoding: .utf8)
            check("complete wrote [x]", disk.contains("- [x] smoke add item"))
            let doneVisible: Bool = await MainActor.run {
                store.sections.flatMap(\.items).contains { $0.text == "smoke add item" && $0.isCompleted }
            }
            check("completed still in model", doneVisible)
        }

        // Edit
        let toEdit: TodoItem? = await MainActor.run {
            store.sections.flatMap(\.items).first { $0.text == "first" && !$0.isCompleted }
        }
        if let toEdit {
            await MainActor.run { store.updateItem(toEdit, text: "first edited") }
            let editIdle = await MainActor.run { !store.isBusy }
            check("edit unlocks", editIdle)
            check("edit on disk", (try? String(contentsOf: md, encoding: .utf8))?.contains("- first edited") == true)
        } else {
            check("edit target exists", false)
        }

        // Wait briefly for async git to finish (should not matter for correctness)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let finalBusy = await MainActor.run { store.isBusy }
        check("still idle after git", !finalBusy)

        if failed == 0 {
            print("\nSMOKE PASS")
            exit(0)
        } else {
            print("\nSMOKE FAIL (\(failed))")
            exit(1)
        }
    }
}
