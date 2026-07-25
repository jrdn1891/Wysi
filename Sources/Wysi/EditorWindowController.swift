import AppKit
import WebKit

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    private static let modeItem = NSToolbarItem.Identifier("mode")

    private var webView: WKWebView!
    private var modeControl: NSSegmentedControl?
    private let bridge = Bridge()
    private var pendingFlush: (() -> Void)?
    private(set) var mode = "preview"

    private var wysiDocument: WysiDocument? { document as? WysiDocument }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        self.init(window: window)
        bridge.controller = self

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WysiSchemeHandler(), forURLScheme: "wysi")
        config.userContentController.add(bridge, name: "wysi")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        window.contentView = webView
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
        webView.evaluateJavaScript("wysi.setMode('\(next)')")
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 1 ? "edit" : "preview")
    }

    fileprivate func receive(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            webView.evaluateJavaScript("wysi.load(\(json(wysiDocument?.html ?? "")), '\(mode)')")
        case "changed":
            if let html = body["html"] as? String { wysiDocument?.htmlEdited(html) }
        case "flushed":
            let pending = pendingFlush
            pendingFlush = nil
            pending?()
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
        guard itemIdentifier == Self.modeItem else { return nil }
        let control = NSSegmentedControl(labels: ["Preview", "Edit"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        control.selectedSegment = 0
        modeControl = control
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = control
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem]
    }
}

private final class Bridge: NSObject, WKScriptMessageHandler {
    weak var controller: EditorWindowController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        controller?.receive(type, body)
    }
}
