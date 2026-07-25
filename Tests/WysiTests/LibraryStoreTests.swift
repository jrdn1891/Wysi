import XCTest
@testable import Wysi

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var folder: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wysi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = LibraryStore(folder: folder)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ html: String) throws {
        try Data(html.utf8).write(to: folder.appendingPathComponent(name))
    }

    func testScanTitlesAndSort() throws {
        try write("older.html", "<html><head><title>  Old Deck  </title></head><body></body></html>")
        try write("newer.html", "<html><body><p>no title</p></body></html>")
        try write("notes.txt", "ignored")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: folder.appendingPathComponent("older.html").path
        )
        store.rescan()

        XCTAssertEqual(store.docs.map(\.title), ["newer", "Old Deck"])
    }

    func testImportCollisionNaming() throws {
        try write("deck.html", "<html><body>original</body></html>")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("deck.html")
        try Data("<html><body>imported</body></html>".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        store.rescan()

        store.importFiles([outside])
        store.importFiles([outside])

        let names = store.docs.map(\.url.lastPathComponent).sorted()
        XCTAssertEqual(names, ["deck 2.html", "deck 3.html", "deck.html"])
    }

    func testRename() throws {
        try write("draft.html", "<html><body></body></html>")
        store.rescan()

        store.rename(store.docs[0], to: "final")

        XCTAssertEqual(store.docs.map(\.url.lastPathComponent), ["final.html"])
    }

    func testWatcherPicksUpExternalWrites() async throws {
        XCTAssertEqual(store.docs.count, 0)
        try write("agent-output.html", "<html><head><title>From an agent</title></head><body></body></html>")

        let deadline = Date().addingTimeInterval(5)
        while store.docs.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(store.docs.map(\.title), ["From an agent"])
    }
}
