import AppKit
import SwiftUI

final class LibraryWindowController: NSWindowController {
    static let shared = LibraryWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WysiLibrary")
        window.toolbarStyle = .unified
        let hosting = NSHostingController(rootView: LibraryView(store: .shared))
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentViewController = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}
