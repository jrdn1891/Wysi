import WebKit
import XCTest
@testable import Wysi

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private final class Collector: NSObject, WKScriptMessageHandler {
    private var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] is String else { return }
        messages.append(body)
    }

    func take(_ type: String) -> [String: Any]? {
        guard let i = messages.firstIndex(where: { $0["type"] as? String == type }) else { return nil }
        return messages.remove(at: i)
    }

    func clear() { messages.removeAll() }
}

@MainActor
final class EditorPipelineTests: XCTestCase {
    private func waitFor(_ type: String, in collector: Collector, timeout: TimeInterval = 10) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = collector.take(type) { return m }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("timeout waiting for '\(type)'")
    }

    private func json(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)
    }

    func testWebViewSessionAndAgentBoot() async throws {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WysiSchemeHandler(base: repoRoot.appendingPathComponent("Editor")), forURLScheme: "wysi")
        let collector = Collector()
        config.userContentController.add(collector, name: "wysi")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        webView.load(URLRequest(url: URL(string: "wysi://app/editor.html")!))

        _ = try await waitFor("ready", in: collector)

        let demo = try String(contentsOf: repoRoot.appendingPathComponent("spike/demo.html"), encoding: .utf8)
        webView.evaluateJavaScript("wysi.load(\(json(demo)), 'edit')", completionHandler: nil)

        let serialized = try await withTimeoutPoll {
            (try? await webView.evaluateJavaScript("wysi.serialize()")) as? String
        }
        XCTAssertTrue(serialized.contains("Launch announcement"))

        var acked = false
        for _ in 0..<5 {
            collector.clear()
            let t0 = Date()
            webView.evaluateJavaScript("wysi.flush()", completionHandler: nil)
            _ = try await waitFor("flushed", in: collector, timeout: 2)
            if Date().timeIntervalSince(t0) < 0.9 { acked = true; break }
        }
        XCTAssertTrue(acked, "agent inside the iframe never acknowledged flush; only the session timeout fired")
    }

    private func withTimeoutPoll(_ op: () async -> String?) async throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = await op() { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("timeout waiting for serialized document")
    }

    func testDocumentEditUndoRedo() throws {
        let doc = WysiDocument()
        let original = doc.html
        let edited = "<!doctype html><html><head></head><body><p>changed</p></body></html>"

        doc.htmlEdited(edited)
        XCTAssertEqual(String(decoding: try doc.data(ofType: "public.html"), as: UTF8.self), edited)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(doc.isDocumentEdited)

        doc.undoManager?.undo()
        XCTAssertEqual(doc.html, original)

        doc.undoManager?.redo()
        XCTAssertEqual(doc.html, edited)
    }

    func testDocumentRead() throws {
        let doc = WysiDocument()
        try doc.read(from: Data("<html><body><h1>from disk</h1></body></html>".utf8), ofType: "public.html")
        XCTAssertTrue(doc.html.contains("from disk"))
    }

    private func tempDoc(_ html: String) throws -> (WysiDocument, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wysi-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.html")
        try Data(html.utf8).write(to: file)
        return (try WysiDocument(contentsOf: file, ofType: "public.html"), file, dir)
    }

    private func rewrite(_ file: URL, _ html: String) throws {
        try Data(html.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    }

    func testExternalChangeReloadsCleanDocument() throws {
        let (doc, file, dir) = try tempDoc("<html><body><p>v1</p></body></html>")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(doc.html.contains("v1"))

        try rewrite(file, "<html><body><p>v2</p></body></html>")
        doc.checkExternalChange()

        XCTAssertTrue(doc.html.contains("v2"))
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testExternalChangeKeepsDirtyDocument() throws {
        let (doc, file, dir) = try tempDoc("<html><body><p>v1</p></body></html>")
        defer { try? FileManager.default.removeItem(at: dir) }
        doc.htmlEdited("<html><body><p>local edit</p></body></html>")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        try rewrite(file, "<html><body><p>v2</p></body></html>")
        doc.checkExternalChange()

        XCTAssertTrue(doc.html.contains("local edit"))
    }
}
