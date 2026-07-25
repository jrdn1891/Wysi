import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    @State private var defaultAppMessage: String?

    var body: some View {
        Form {
            LabeledContent("Library folder") {
                HStack {
                    Text(store.folder.path)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Button("Change…") { pickFolder() }
                }
            }
            LabeledContent("Default editor") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Make WYSI the default app for HTML files") { makeDefault() }
                    if let defaultAppMessage {
                        Text(defaultAppMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url, forKey: "libraryFolder")
            store.relocate(to: url)
        }
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .html) { error in
            DispatchQueue.main.async {
                defaultAppMessage = error.map(\.localizedDescription) ?? "WYSI is now the default HTML editor."
            }
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: .shared))
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}
