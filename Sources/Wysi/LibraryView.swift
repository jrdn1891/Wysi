import SwiftUI
import WebKit

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @State private var filter = ""
    @State private var renaming: LibraryDoc?
    @State private var renameText = ""

    private var shown: [LibraryDoc] {
        guard !filter.isEmpty else { return store.docs }
        return store.docs.filter {
            $0.title.localizedCaseInsensitiveContains(filter) ||
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        Group {
            if store.docs.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls)
            return true
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
                Text("^[\(shown.count) document](inflect: true)")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(shown) { doc in
                        DocCard(doc: doc, store: store, renaming: $renaming, renameText: $renameText)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop HTML files here")
                .font(.title3)
            Text(store.folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocCard: View {
    let doc: LibraryDoc
    let store: LibraryStore
    @Binding var renaming: LibraryDoc?
    @Binding var renameText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DocThumbnail(url: doc.url, mtime: doc.modified)
                .aspectRatio(1.6, contentMode: .fit)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            if renaming == doc {
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.rename(doc, to: renameText)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(doc.title)
                    .lineLimit(1)
            }
            Text(doc.modified, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Open") { open() }
            Button("Rename") {
                renameText = doc.url.deletingPathExtension().lastPathComponent
                renaming = doc
            }
            Button("Duplicate") { store.duplicate(doc) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
            Button("Move to Trash", role: .destructive) { store.trash(doc) }
        }
        .onDrag { NSItemProvider(contentsOf: doc.url) ?? NSItemProvider() }
    }

    private func open() {
        NSDocumentController.shared.openDocument(withContentsOf: doc.url, display: true) { _, _, _ in }
    }
}

private struct DocThumbnail: NSViewRepresentable {
    let url: URL
    let mtime: Date

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.magnification = 0.25
        let key = "\(url.path)|\(mtime.timeIntervalSince1970)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator {
        var key: String?
    }
}
