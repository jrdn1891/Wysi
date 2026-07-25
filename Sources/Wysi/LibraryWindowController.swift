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
    private static let collapsedSearchWidth: CGFloat = 30
    private static let expandedSearchWidth: CGFloat = 240

    private let chrome = LibraryChrome()
    private var searchField: CollapsingSearchField?
    private var searchWidth: NSLayoutConstraint?
    private var searchClickMonitor: Any?

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

    @objc func showFind(_ sender: Any?) {
        expandSearchField()
    }

    private var searchExpanded: Bool {
        (searchWidth?.constant ?? 0) > Self.collapsedSearchWidth
    }

    private func expandSearchField() {
        guard let searchField, let searchWidth else { return }
        if !searchExpanded {
            animateSearch(searchWidth, to: Self.expandedSearchWidth)
            searchClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.searchField else { return event }
                let outside = event.window != self.window
                    || !field.convert(field.bounds, to: nil).contains(event.locationInWindow)
                if outside { self.collapseSearchField() }
                return event
            }
        }
        window?.makeFirstResponder(searchField)
    }

    private func collapseSearchField() {
        guard let searchField, let searchWidth, searchExpanded else { return }
        if let searchClickMonitor {
            NSEvent.removeMonitor(searchClickMonitor)
            self.searchClickMonitor = nil
        }
        searchField.stringValue = ""
        chrome.search = ""
        animateSearch(searchWidth, to: Self.collapsedSearchWidth)
        window?.makeFirstResponder(nil)
    }

    private func animateSearch(_ constraint: NSLayoutConstraint, to width: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            constraint.animator().constant = width
            searchField?.superview?.layoutSubtreeIfNeeded()
        }
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
            let field = CollapsingSearchField()
            field.placeholderString = "Search"
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            let width = field.widthAnchor.constraint(equalToConstant: Self.collapsedSearchWidth)
            width.isActive = true
            field.onFocus = { [weak self] in self?.expandSearchField() }
            searchField = field
            searchWidth = width
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.view = field
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

final class CollapsingSearchField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}
