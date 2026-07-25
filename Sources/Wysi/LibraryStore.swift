import AppKit

struct LibraryDoc: Identifiable, Hashable {
    let url: URL
    let title: String
    let modified: Date
    var id: URL { url }
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
        folder: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WYSI")
    )

    let folder: URL
    @Published private(set) var docs: [LibraryDoc] = []
    private var watcher: FolderWatcher?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = FolderWatcher(folder: folder) { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        rescan()
    }

    func rescan() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        docs = urls
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return LibraryDoc(url: url, title: Self.title(of: url), modified: mtime)
            }
            .sorted { $0.modified > $1.modified }
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

    func importFiles(_ urls: [URL]) {
        for src in urls where ["html", "htm"].contains(src.pathExtension.lowercased()) {
            try? FileManager.default.copyItem(at: src, to: freeSlot(for: src.lastPathComponent))
        }
        rescan()
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
