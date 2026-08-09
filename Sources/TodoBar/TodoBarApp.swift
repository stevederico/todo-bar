import SwiftUI
import AppKit

@main
struct TodoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TodoBarModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar only; `--demo-window` hosts ContentView in a normal NSWindow for screenshots.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDemoWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-window")
    }

    private var hostedWindow: NSWindow?
    /// Retained so the demo window's ObservableObject stays alive.
    private var demoModel: TodoBarModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay accessory even for demo (regular + MenuBarExtra can fatal).
        NSApp.setActivationPolicy(.accessory)
        guard isDemoWindow else { return }
        DispatchQueue.main.async { [weak self] in
            self?.openDemoWindow()
        }
    }

    @MainActor
    private func openDemoWindow() {
        guard hostedWindow == nil else { return }
        let model = TodoBarModel()
        demoModel = model
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "todo-bar"
        window.contentView = hosting
        window.setContentSize(NSSize(width: 460, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hostedWindow = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
