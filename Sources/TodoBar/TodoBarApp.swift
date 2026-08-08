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
            Label {
                Text("todo-bar")
            } icon: {
                Image(systemName: "checklist")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keep the app out of the Dock; menu bar only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
