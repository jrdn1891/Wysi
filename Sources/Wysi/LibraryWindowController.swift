import AppKit
import SwiftUI

@MainActor
final class LibraryChrome: ObservableObject {
    @Published var sidebarVisible = true
    @Published var search = ""
}

final class LibraryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    static let shared = LibraryWindowController()

    private static let sidebarItem = NSToolbarItem.Identifier("sidebar")
    private static let searchItem = NSToolbarItem.Identifier("search")

    private let chrome = LibraryChrome()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WysiLibrary")
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: LibraryView(store: .shared, chrome: chrome))
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    @objc private func toggleLibrarySidebar(_ sender: Any?) {
        chrome.sidebarVisible.toggle()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        chrome.search = field.stringValue
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleLibrarySidebar(_:))
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search titles and content"
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 240
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace, Self.searchItem]
    }
}
