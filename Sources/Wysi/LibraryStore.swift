import AppKit

struct LibraryDoc: Identifiable, Hashable {
    let url: URL
    let title: String
    let modified: Date
    let favorite: Bool
    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

final class FolderWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue().onChange()
            },
            &context,
            [folder.resolvingSymlinksInPath().path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore(
        folder: UserDefaults.standard.url(forKey: "libraryFolder")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WYSI")
    )

    @Published private(set) var folder: URL
    @Published private(set) var docs: [LibraryDoc] = []
    private var watcher: FolderWatcher?

    init(folder: URL) {
        self.folder = folder
        watch()
    }

    func relocate(to url: URL) {
        folder = url
        watch()
    }

    func contains(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    private func watch() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = FolderWatcher(folder: folder) { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        rescan()
    }

    func rescan() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .tagNamesKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        docs = urls
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .tagNamesKey])
                return LibraryDoc(
                    url: url,
                    title: Self.title(of: url),
                    modified: values?.contentModificationDate ?? .distantPast,
                    favorite: values?.tagNames?.contains("Favorite") ?? false
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    private var textCache: [URL: (mtime: Date, text: String)] = [:]

    func contentSnippet(_ doc: LibraryDoc, matching query: String) -> String? {
        let text = extractedText(doc)
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private func extractedText(_ doc: LibraryDoc) -> String {
        if let cached = textCache[doc.url], cached.mtime == doc.modified { return cached.text }
        let html = (try? String(contentsOf: doc.url, encoding: .utf8)) ?? ""
        let text = Self.textContent(of: html)
        textCache[doc.url] = (doc.modified, text)
        return text
    }

    static func textContent(of html: String) -> String {
        var s = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func toggleFavorite(_ doc: LibraryDoc) {
        let ns = doc.url as NSURL
        var tags = ((try? ns.resourceValues(forKeys: [.tagNamesKey])[.tagNamesKey]) as? [String]) ?? []
        if let i = tags.firstIndex(of: "Favorite") { tags.remove(at: i) } else { tags.append("Favorite") }
        try? ns.setResourceValue(tags as NSArray, forKey: .tagNamesKey)
        rescan()
    }

    static func title(of url: URL) -> String {
        if let handle = try? FileHandle(forReadingFrom: url),
           let data = try? handle.read(upToCount: 262_144),
           let head = String(data: data, encoding: .utf8),
           let regex = try? Regex("(?i)<title[^>]*>\\s*([^<]+?)\\s*</title>"),
           let match = head.firstMatch(of: regex),
           let title = match[1].substring {
            return String(title)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    @discardableResult
    func importFile(_ src: URL) -> URL? {
        guard ["html", "htm"].contains(src.pathExtension.lowercased()) else { return nil }
        let dest = freeSlot(for: src.lastPathComponent)
        do { try FileManager.default.copyItem(at: src, to: dest) } catch { return nil }
        rescan()
        return dest
    }

    func importFiles(_ urls: [URL]) {
        for src in urls { importFile(src) }
    }

    func duplicate(_ doc: LibraryDoc) {
        try? FileManager.default.copyItem(at: doc.url, to: freeSlot(for: doc.url.lastPathComponent))
        rescan()
    }

    func rename(_ doc: LibraryDoc, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let dest = folder.appendingPathComponent(clean).appendingPathExtension(doc.url.pathExtension)
        guard dest != doc.url else { return }
        try? FileManager.default.moveItem(at: doc.url, to: dest)
        rescan()
    }

    func trash(_ doc: LibraryDoc) {
        try? FileManager.default.trashItem(at: doc.url, resultingItemURL: nil)
        rescan()
    }

    private func freeSlot(for filename: String) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var dest = folder.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return dest
    }
}
