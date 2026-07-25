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
    private static let searchIconItem = NSToolbarItem.Identifier("searchIcon")

    private let chrome = LibraryChrome()
    private var searchToolbarItem: NSSearchToolbarItem?

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

    @objc private func expandSearch(_ sender: Any?) {
        expandSearchField()
    }

    @objc func showFind(_ sender: Any?) {
        expandSearchField()
    }

    private func expandSearchField() {
        guard let toolbar = window?.toolbar else { return }
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.searchIconItem }) {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: Self.searchItem, at: index)
        }
        searchToolbarItem?.beginSearchInteraction()
    }

    private func collapseSearchField() {
        guard let toolbar = window?.toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.searchItem })
        else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: Self.searchIconItem, at: index)
        searchToolbarItem = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        chrome.search = field.stringValue
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field.stringValue.isEmpty else { return }
        collapseSearchField()
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
            searchToolbarItem = item
            return item
        case Self.searchIconItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            item.isBordered = true
            item.target = self
            item.action = #selector(expandSearch(_:))
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace, Self.searchIconItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace, Self.searchItem, Self.searchIconItem]
    }
}
