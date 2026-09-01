import SwiftUI
import AppKit

@main
struct TodoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TodoBarModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                model: model,
                store: model.store,
                compact: true,
                onOpenWindow: { appDelegate.openTodoWindow() }
            )
            .frame(width: 460, height: 560)
            .onAppear { appDelegate.attach(model: model) }
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar app with an optional normal window (same model + store as the panel).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var model: TodoBarModel?
    private var todoWindow: NSWindow?

    var isTodoWindowOpen: Bool {
        todoWindow?.isVisible == true
    }

    func attach(model: TodoBarModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard ProcessInfo.processInfo.arguments.contains("--demo-window") else { return }
        DispatchQueue.main.async { [weak self] in
            self?.openTodoWindow()
        }
    }

    func openTodoWindow() {
        guard let model else { return }
        if let todoWindow {
            todoWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let content = ContentView(
            model: model,
            store: model.store,
            compact: false,
            onCloseWindow: { [weak self] in self?.closeTodoWindow() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "todo-bar"
        window.contentView = hosting
        window.minSize = NSSize(width: 400, height: 480)
        window.setContentSize(NSSize(width: 520, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        todoWindow = window
        model.store.syncFromRemote()
    }

    func closeTodoWindow() {
        todoWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === todoWindow else { return }
        todoWindow = nil
        NSApp.setActivationPolicy(.accessory)
        model?.store.syncFromRemote()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
