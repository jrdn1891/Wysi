import AppKit
import SwiftUI
import WebKit

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, WKUIDelegate, NSSharingServicePickerToolbarItemDelegate, NSPopoverDelegate {
    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let playItem = NSToolbarItem.Identifier("play")
    private static let undoItem = NSToolbarItem.Identifier("undo")
    private static let redoItem = NSToolbarItem.Identifier("redo")
    private static let undoRedoItem = NSToolbarItem.Identifier("undoRedo")
    private static let shareItem = NSToolbarItem.Identifier("share")
    private static let themeItem = NSToolbarItem.Identifier("theme")
    private static let addLibraryItem = NSToolbarItem.Identifier("addLibrary")

    private var webView: WKWebView!
    private var modeControl: NSSegmentedControl?
    private let bridge = Bridge()
    private var pendingFlush: (() -> Void)?
    private(set) var mode = "preview"
    private var themeButton: NSButton?
    private var themeRaw: [[String: Any]] = []
    private var themeModel: ThemeModel?
    private var themePopover: NSPopover?
    private var findAccessory: NSTitlebarAccessoryViewController?
    private let findModel = FindModel()
    private var undoToolbarItem: NSToolbarItem?
    private var redoToolbarItem: NSToolbarItem?

    private var wysiDocument: WysiDocument? { document as? WysiDocument }

    override var document: AnyObject? {
        didSet {
            guard let url = wysiDocument?.fileURL, !LibraryStore.shared.contains(url),
                  let toolbar = window?.toolbar,
                  !toolbar.items.contains(where: { $0.itemIdentifier == Self.addLibraryItem })
            else { return }
            toolbar.insertItem(withItemIdentifier: Self.addLibraryItem, at: 0)
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        self.init(window: window)
        bridge.controller = self

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WysiSchemeHandler(), forURLScheme: "wysi")
        config.userContentController.add(bridge, name: "wysi")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.uiDelegate = self
        let base = NSVisualEffectView()
        base.material = .underWindowBackground
        base.blendingMode = .behindWindow
        base.state = .followsWindowActiveState
        window.contentView = base
        webView.translatesAutoresizingMaskIntoConstraints = false
        base.addSubview(webView)
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: guide.topAnchor),
                webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            ])
        }
        self.webView = webView

        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        window.toolbar = toolbar

        webView.load(URLRequest(url: URL(string: "wysi://app/editor.html")!))
    }

    func documentReplaced() {
        guard let html = wysiDocument?.html else { return }
        webView.evaluateJavaScript("wysi.load(\(json(html)))")
    }

    func flush(_ completion: @escaping () -> Void) {
        guard mode == "edit", pendingFlush == nil else { return completion() }
        pendingFlush = completion
        webView.evaluateJavaScript("wysi.flush()")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let pending = self.pendingFlush else { return }
            self.pendingFlush = nil
            pending()
        }
    }

    @objc func toggleMode(_ sender: Any?) {
        setMode(mode == "edit" ? "preview" : "edit")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleMode(_:)) {
            menuItem.state = mode == "edit" ? .on : .off
        }
        return true
    }

    private func setMode(_ next: String) {
        guard next != mode else { return }
        mode = next
        modeControl?.selectedSegment = next == "edit" ? 1 : 0
        themeButton?.isEnabled = next == "edit"
        if next != "edit" {
            themeRaw = []
            themePopover?.performClose(nil)
        }
        webView.evaluateJavaScript("wysi.setMode('\(next)')")
        updateUndoRedoItems()
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func showTheme(_ sender: NSButton) {
        if let popover = themePopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let model = ThemeModel(
            raw: themeRaw,
            preview: { [weak self] index, value in
                guard let self else { return }
                self.webView.evaluateJavaScript("wysi.themePreview(\(index), \(self.json(value)))")
            },
            commit: { [weak self] index, value in
                guard let self else { return }
                self.webView.evaluateJavaScript("wysi.themeCommit(\(index), \(self.json(value)))")
            }
        )
        themeModel = model
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ThemePanel(model: model))
        popover.delegate = self
        themePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func popoverWillClose(_ notification: Notification) {
        themeModel?.commitDirty()
    }

    @objc func showFind(_ sender: Any?) {
        hideFind()
        let accessory = NSTitlebarAccessoryViewController()
        let view = NSHostingView(rootView: FindBar(model: findModel))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 34)
        accessory.view = view
        accessory.layoutAttribute = .bottom
        findModel.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findModel.onClose = { [weak self] in self?.hideFind() }
        window?.addTitlebarAccessoryViewController(accessory)
        findAccessory = accessory
    }

    @objc func findNext(_ sender: Any?) {
        find(findModel.text, backwards: false)
    }

    @objc func findPrevious(_ sender: Any?) {
        find(findModel.text, backwards: true)
    }

    private func hideFind() {
        if let findAccessory, let index = window?.titlebarAccessoryViewControllers.firstIndex(of: findAccessory) {
            window?.removeTitlebarAccessoryViewController(at: index)
        }
        findAccessory = nil
        window?.makeFirstResponder(webView)
    }

    private func find(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        webView.evaluateJavaScript("wysi.find(\(json(text)), \(backwards))")
    }

    @objc private func undoClicked(_ sender: Any?) {
        wysiDocument?.undoManager?.undo()
        refreshUndoRedo()
    }

    @objc private func redoClicked(_ sender: Any?) {
        wysiDocument?.undoManager?.redo()
        refreshUndoRedo()
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.undoItem: return wysiDocument?.undoManager?.canUndo ?? false
        case Self.redoItem: return wysiDocument?.undoManager?.canRedo ?? false
        default: return true
        }
    }

    private func updateUndoRedoItems() {
        guard let toolbar = window?.toolbar else { return }
        let present = toolbar.items.contains { $0.itemIdentifier == Self.undoRedoItem }
        if mode == "edit" && !present {
            toolbar.insertItem(withItemIdentifier: Self.undoRedoItem, at: 0)
        } else if mode != "edit" && present {
            for (index, item) in toolbar.items.enumerated().reversed()
            where item.itemIdentifier == Self.undoRedoItem {
                toolbar.removeItem(at: index)
            }
            undoToolbarItem = nil
            redoToolbarItem = nil
        }
        refreshUndoRedo()
    }

    private func refreshUndoRedo() {
        undoToolbarItem?.isEnabled = wysiDocument?.undoManager?.canUndo ?? false
        redoToolbarItem?.isEnabled = wysiDocument?.undoManager?.canRedo ?? false
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 1 ? "edit" : "preview")
    }

    @objc private func play(_ sender: Any?) {
        setMode("preview")
        window?.toggleFullScreen(sender)
    }

    @objc private func addToLibrary(_ sender: Any?) {
        guard let doc = wysiDocument, let url = doc.fileURL else { return }
        doc.save(to: url, ofType: doc.fileType ?? "public.html", for: .saveOperation) { _ in
            guard let dest = LibraryStore.shared.importFile(url) else { return }
            NSDocumentController.shared.openDocument(withContentsOf: dest, display: true) { _, _, _ in
                doc.close()
            }
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        [wysiDocument?.fileURL].compactMap { $0 }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    fileprivate func receive(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            webView.evaluateJavaScript("wysi.load(\(json(wysiDocument?.html ?? "")), '\(mode)')")
        case "changed":
            if let html = body["html"] as? String { wysiDocument?.htmlEdited(html) }
            refreshUndoRedo()
        case "flushed":
            let pending = pendingFlush
            pendingFlush = nil
            pending?()
        case "theme":
            themeRaw = body["entries"] as? [[String: Any]] ?? []
        case "found":
            if body["found"] as? Bool == false { NSSound.beep() }
        case "undo":
            wysiDocument?.undoManager?.undo()
        case "redo":
            wysiDocument?.undoManager?.redo()
        case "error":
            NSSound.beep()
        default:
            break
        }
    }

    private func json(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.modeItem:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")!,
                NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")!,
            ], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
            control.setToolTip("Preview", forSegment: 0)
            control.setToolTip("Edit", forSegment: 1)
            control.selectedSegment = 0
            modeControl = control
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            return item
        case Self.playItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Play"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            item.isBordered = true
            item.target = self
            item.action = #selector(play(_:))
            return item
        case Self.undoRedoItem:
            let undo = NSToolbarItem(itemIdentifier: Self.undoItem)
            undo.label = "Undo"
            undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
            undo.isBordered = true
            undo.target = self
            undo.action = #selector(undoClicked(_:))
            let redo = NSToolbarItem(itemIdentifier: Self.redoItem)
            redo.label = "Redo"
            redo.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")
            redo.isBordered = true
            redo.target = self
            redo.action = #selector(redoClicked(_:))
            undoToolbarItem = undo
            redoToolbarItem = redo
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.label = "Undo/Redo"
            group.subitems = [undo, redo]
            refreshUndoRedo()
            return group
        case Self.themeItem:
            let button = NSButton(image: NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Theme")!, target: self, action: #selector(showTheme(_:)))
            button.bezelStyle = .texturedRounded
            button.isEnabled = mode == "edit"
            themeButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Theme"
            item.view = button
            return item
        case Self.shareItem:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.delegate = self
            return item
        case Self.addLibraryItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add to Library"
            item.image = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: "Add to Library")
            item.isBordered = true
            item.target = self
            item.action = #selector(addToLibrary(_:))
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, .flexibleSpace, Self.themeItem, Self.shareItem, Self.playItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, Self.playItem, Self.themeItem, Self.shareItem, Self.undoRedoItem, Self.addLibraryItem]
    }
}

private final class Bridge: NSObject, WKScriptMessageHandler {
    weak var controller: EditorWindowController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        controller?.receive(type, body)
    }
}
