import AppKit
import SwiftUI
import ShitsuraeCore

// v2 GUI: menu-bar resident SwiftUI app. The app process is the single owner
// of virtual workspace state and serves the CLI over a unix socket — there is
// no separate agent process anymore.

/// The bundled template icon (menu-22/44.png, same as v1). Falls back to nil
/// in dev builds run outside an app bundle.
private let menuBarIconImage: NSImage? = {
    let image = NSImage(size: NSSize(width: 22, height: 22))

    for fileName in ["menu-22.png", "menu-44.png"] {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: resourceURL),
              let representation = NSBitmapImageRep(data: data)
        else {
            continue
        }
        image.addRepresentation(representation)
    }

    guard !image.representations.isEmpty else {
        return nil
    }
    image.isTemplate = true
    return image
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    static nonisolated(unsafe) var sharedModel: AppModel?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for Accessibility on first launch — the whole app needs it.
        if !SystemProbe.accessibilityGranted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        Self.sharedModel?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.sharedModel else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }

        terminationPending = true
        model.shutdown { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ShitsuraeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.sharedModel = model
    }

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            if let menuBarIconImage {
                Image(nsImage: menuBarIconImage)
            } else {
                Image(systemName: "rectangle.3.group")
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Shitsurae", id: "main") {
            MainWindowView()
                .environmentObject(model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 860, height: 560)
        // Show the main window on app launch (menu-bar apps suppress it by
        // default).
        .defaultLaunchBehavior(.presented)
    }

    @ViewBuilder
    private var menuContent: some View {
        ForEach(model.layouts, id: \.self) { layout in
            Menu(layout) {
                Button("Apply All") {
                    model.applyLayout(layout, spaceID: nil)
                }
                Button("Apply Current Space") {
                    model.applyLayout(layout, spaceID: model.activeSpaceID ?? model.selectedSpaceID)
                }
            }
        }

        if !model.layouts.isEmpty {
            Divider()
        }

        Button("Open Shitsurae") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Config Directory") {
            model.openConfigDirectory()
        }

        Divider()

        Button("Quit Shitsurae") {
            NSApp.terminate(nil)
        }
    }
}

ShitsuraeApp.main()
