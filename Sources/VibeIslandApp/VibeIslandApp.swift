import AppKit
import SwiftUI

@MainActor
final class VibeIslandAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var controlCenterWindowController = ControlCenterWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [self] in
            model.attach(controlCenterWindowController: controlCenterWindowController)
            controlCenterWindowController.show()
            model.startIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlCenterWindowController.show()
        return false
    }
}

@main
struct VibeIslandApp: App {
    @NSApplicationDelegateAdaptor(VibeIslandAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        MenuBarExtra("Vibe Island", systemImage: "circle.hexagongrid.circle.fill") {
            MenuBarContentView(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
