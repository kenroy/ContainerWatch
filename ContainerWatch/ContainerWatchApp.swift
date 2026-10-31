import SwiftUI
import Observation

@main
struct ContainerWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu bar item and popover are managed by AppDelegate; SwiftUI needs at least one scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--report") || args.contains("--json") {
            // Headless mode: print the scan and exit, so scripts can call the app binary directly.
            Task {
                do {
                    let rows = try await Store.oneShot()
                    let output = args.contains("--json") ? Report.json(rows) : Data(Report.text(rows).utf8)
                    FileHandle.standardOutput.write(output)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        let store = Store.shared

        let controller = NSHostingController(rootView: MenuView(store: store))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        updateButton()
        store.start()
    }

    /// Re-renders the menu bar icon whenever the number of available updates changes.
    private func updateButton() {
        let count = withObservationTracking {
            Store.shared.updateCount
        } onChange: {
            Task { @MainActor in self.updateButton() }
        }
        let name = count > 0 ? "shippingbox.fill" : "shippingbox"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "ContainerWatch")
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
