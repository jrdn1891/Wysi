import AppKit

private let starterHTML = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Untitled</title>
<style>
body { font: 18px/1.6 -apple-system, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; }
</style>
</head>
<body>
<h1>Untitled</h1>
<p>Switch to Edit mode and click any text to change it.</p>
</body>
</html>
"""

@objc(WysiDocument)
final class WysiDocument: NSDocument {
    var html = starterHTML
    weak var editor: EditorWindowController?

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let controller = EditorWindowController()
        addWindowController(controller)
        editor = controller
    }

    override func read(from data: Data, ofType typeName: String) throws {
        html = String(decoding: data, as: UTF8.self)
        editor?.documentReplaced()
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(html.utf8)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil { savePanel.directoryURL = LibraryStore.shared.folder }
        return true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        guard let editor else {
            return super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
        editor.flush {
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
    }

    func htmlEdited(_ new: String) {
        apply(new, reload: false)
    }

    private func apply(_ new: String, reload: Bool) {
        guard new != html else { return }
        let old = html
        undoManager?.registerUndo(withTarget: self) { $0.apply(old, reload: true) }
        html = new
        if reload { editor?.documentReplaced() }
    }

    @objc func docUndo(_ sender: Any?) { undoManager?.undo() }
    @objc func docRedo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(docUndo(_:)): return undoManager?.canUndo ?? false
        case #selector(docRedo(_:)): return undoManager?.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
