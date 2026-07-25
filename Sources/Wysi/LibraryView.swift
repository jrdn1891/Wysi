import SwiftUI
import WebKit

private enum LibraryScope: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }
    var label: String { self == .all ? "All Files" : "Favorites" }
    var symbol: String { self == .all ? "tray.full" : "star" }
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var chrome: LibraryChrome
    @AppStorage("libraryViewMode") private var viewMode = "grid"
    @State private var scope: LibraryScope? = .all
    @State private var sortOrder = [KeyPathComparator(\LibraryDoc.modified, order: .reverse)]
    @State private var selection = Set<LibraryDoc.ID>()
    @State private var renaming: LibraryDoc?
    @State private var renameText = ""

    private var filter: String { chrome.search }

    private var shown: [LibraryDoc] {
        var docs = store.docs
        if scope == .favorites { docs = docs.filter(\.favorite) }
        if !filter.isEmpty {
            docs = docs.filter {
                $0.title.localizedCaseInsensitiveContains(filter) ||
                $0.filename.localizedCaseInsensitiveContains(filter) ||
                store.contentSnippet($0, matching: filter) != nil
            }
        }
        return docs.sorted(using: sortOrder)
    }

    private func snippet(for doc: LibraryDoc) -> String? {
        filter.isEmpty ? nil : store.contentSnippet(doc, matching: filter)
    }

    var body: some View {
        HStack(spacing: 0) {
            if chrome.sidebarVisible {
                List(selection: $scope) {
                    ForEach(LibraryScope.allCases) { s in
                        Label(s.label, systemImage: s.symbol).tag(s)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 180)
                Divider()
            }
            VStack(spacing: 0) {
                controls
                if shown.isEmpty {
                    emptyState
                } else if viewMode == "grid" {
                    grid
                } else {
                    table
                }
            }
        }
        .animation(.default, value: chrome.sidebarVisible)
        .frame(minWidth: 780, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls)
            return true
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming { store.rename(renaming, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag("grid")
                Image(systemName: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Date Modified") { sortOrder = [KeyPathComparator(\LibraryDoc.modified, order: .reverse)] }
                Button("Title") { sortOrder = [KeyPathComparator(\LibraryDoc.title)] }
                Button("File Name") { sortOrder = [KeyPathComparator(\LibraryDoc.filename)] }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            Spacer()
            Text("^[\(shown.count) document](inflect: true)")
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
                ForEach(shown) { doc in
                    DocCard(doc: doc, snippet: snippet(for: doc), open: { open(doc) }) {
                        menuItems(for: [doc])
                    }
                }
            }
            .padding(14)
        }
    }

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { doc in
                Button { store.toggleFavorite(doc) } label: {
                    Image(systemName: doc.favorite ? "star.fill" : "star")
                        .foregroundStyle(doc.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
            .width(24)
            TableColumn("Title", value: \.title) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                    if let snippet = snippet(for: doc) {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            TableColumn("File", value: \.filename)
            TableColumn("Modified", value: \.modified) { doc in
                Text(doc.modified, format: .relative(presentation: .named))
            }
        }
        .contextMenu(forSelectionType: LibraryDoc.ID.self) { ids in
            menuItems(for: docs(for: ids))
        } primaryAction: { ids in
            for doc in docs(for: ids) { open(doc) }
        }
    }

    private func docs(for ids: Set<LibraryDoc.ID>) -> [LibraryDoc] {
        store.docs.filter { ids.contains($0.id) }
    }

    private func open(_ doc: LibraryDoc) {
        NSDocumentController.shared.openDocument(withContentsOf: doc.url, display: true) { _, _, _ in }
    }

    @ViewBuilder
    private func menuItems(for docs: [LibraryDoc]) -> some View {
        if docs.count == 1, let doc = docs.first {
            Button { open(doc) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button {
                renameText = doc.url.deletingPathExtension().lastPathComponent
                renaming = doc
            } label: { Label("Rename…", systemImage: "pencil") }
        }
        Button {
            for doc in docs { store.toggleFavorite(doc) }
        } label: {
            if docs.allSatisfy(\.favorite) {
                Label("Unfavorite", systemImage: "star.slash")
            } else {
                Label("Favorite", systemImage: "star")
            }
        }
        Button {
            for doc in docs { store.duplicate(doc) }
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Divider()
        if docs.count == 1, let doc = docs.first {
            ShareLink(item: doc.url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting(docs.map(\.url))
        } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button(role: .destructive) {
            for doc in docs { store.trash(doc) }
        } label: { Label("Move to Trash", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: scope == .favorites ? "star" : "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(scope == .favorites ? "No favorites yet" : "Drop HTML files here")
                .font(.title3)
            Text(scope == .favorites ? "Right-click any file and choose Favorite." : store.folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocCard<Menu: View>: View {
    let doc: LibraryDoc
    let snippet: String?
    let open: () -> Void
    let menu: () -> Menu

    init(doc: LibraryDoc, snippet: String?, open: @escaping () -> Void, @ViewBuilder menu: @escaping () -> Menu) {
        self.doc = doc
        self.snippet = snippet
        self.open = open
        self.menu = menu
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DocThumbnail(url: doc.url, mtime: doc.modified)
                .aspectRatio(1.6, contentMode: .fit)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topTrailing) {
                    if doc.favorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                }
            Text(doc.title)
                .lineLimit(1)
            if let snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(doc.modified, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu { menu() }
        .onDrag { NSItemProvider(contentsOf: doc.url) ?? NSItemProvider() }
    }
}

private final class InertWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

private struct DocThumbnail: NSViewRepresentable {
    let url: URL
    let mtime: Date

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        InertWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.magnification = 0.15
        let key = "\(url.path)|\(mtime.timeIntervalSince1970)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator {
        var key: String?
    }
}
