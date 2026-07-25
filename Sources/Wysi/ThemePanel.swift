import SwiftUI

private let fontStacks: [(name: String, value: String)] = [
    ("System", "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"),
    ("Inter", "'Inter', -apple-system, BlinkMacSystemFont, sans-serif"),
    ("Helvetica Neue", "'Helvetica Neue', Helvetica, Arial, sans-serif"),
    ("Georgia", "Georgia, 'Times New Roman', serif"),
    ("Palatino", "'Palatino Linotype', Palatino, Georgia, serif"),
    ("SF Mono", "'SF Mono', ui-monospace, Menlo, monospace"),
]

@MainActor
final class ThemeModel: ObservableObject {
    struct Entry: Identifiable {
        let index: Int
        let kind: String
        let name: String
        let value: String
        let rgba: (Double, Double, Double, Double)?
        var id: Int { index }
        var label: String {
            name.replacingOccurrences(of: "--", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    @Published var colorState: [Int: Color] = [:]
    @Published var fontState: [Int: String] = [:]
    @Published var sizeState: [Int: Double] = [:]
    private(set) var sizeUnit: [Int: String] = [:]
    private(set) var entries: [Entry] = []

    private var pending: [Int: String] = [:]
    private var dirty: Set<Int> = []
    private var debounce: DispatchWorkItem?
    private let preview: (Int, String) -> Void
    private let commit: (Int, String) -> Void

    init(raw: [[String: Any]], preview: @escaping (Int, String) -> Void, commit: @escaping (Int, String) -> Void) {
        self.preview = preview
        self.commit = commit
        entries = raw.compactMap { dict in
            guard let index = dict["index"] as? Int,
                  let kind = dict["kind"] as? String,
                  let name = dict["name"] as? String,
                  let value = dict["value"] as? String
            else { return nil }
            var rgba: (Double, Double, Double, Double)?
            if let c = dict["rgba"] as? [String: Any],
               let r = c["r"] as? Double, let g = c["g"] as? Double, let b = c["b"] as? Double {
                rgba = (r, g, b, c["a"] as? Double ?? 1)
            }
            return Entry(index: index, kind: kind, name: name, value: value, rgba: rgba)
        }
        for e in entries {
            switch e.kind {
            case "color":
                if let (r, g, b, a) = e.rgba {
                    colorState[e.index] = Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
                }
            case "font":
                fontState[e.index] = e.value
            case "size":
                let (n, u) = Self.parseSize(e.value)
                sizeState[e.index] = n
                sizeUnit[e.index] = u
            default:
                break
            }
        }
    }

    func of(kind: String) -> [Entry] {
        entries.filter { $0.kind == kind }
    }

    func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { self.colorState[index] ?? .black },
            set: {
                self.colorState[index] = $0
                self.changed(index, Self.css(from: $0))
            }
        )
    }

    func fontBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { self.fontState[index] ?? "" },
            set: {
                self.fontState[index] = $0
                self.changed(index, $0)
            }
        )
    }

    func sizeBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { self.sizeState[index] ?? 0 },
            set: {
                self.sizeState[index] = $0
                self.changed(index, Self.formatSize($0) + (self.sizeUnit[index] ?? ""))
            }
        )
    }

    func sizeStep(_ index: Int) -> Double {
        switch sizeUnit[index] {
        case "rem", "em": return 0.125
        case "vw", "vh": return 0.5
        default: return 1
        }
    }

    func commitDirty() {
        for index in dirty {
            if let value = pending[index] { commit(index, value) }
        }
        dirty.removeAll()
        debounce?.cancel()
    }

    private func changed(_ index: Int, _ css: String) {
        preview(index, css)
        pending[index] = css
        dirty.insert(index)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitDirty() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    static func css(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        if ns.alphaComponent >= 0.999 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return "rgba(\(r), \(g), \(b), \(String(format: "%.3g", ns.alphaComponent)))"
    }

    static func parseSize(_ value: String) -> (Double, String) {
        let scanner = Scanner(string: value)
        let n = scanner.scanDouble() ?? 0
        return (n, String(value[scanner.currentIndex...]))
    }

    static func formatSize(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(n)
    }
}

struct ThemePanel: View {
    @ObservedObject var model: ThemeModel

    var body: some View {
        if model.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("This document doesn't expose theme variables.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(width: 300)
        } else {
            Form {
                let colors = model.of(kind: "color")
                let fonts = model.of(kind: "font")
                let sizes = model.of(kind: "size")
                if !colors.isEmpty {
                    Section("Colors") {
                        ForEach(colors) { entry in
                            ColorPicker(entry.label, selection: model.colorBinding(entry.index), supportsOpacity: true)
                        }
                    }
                }
                if !fonts.isEmpty {
                    Section("Fonts") {
                        ForEach(fonts) { entry in
                            Picker(entry.label, selection: model.fontBinding(entry.index)) {
                                if !fontStacks.contains(where: { $0.value == model.fontState[entry.index] ?? "" }) {
                                    Text("Original").tag(model.fontState[entry.index] ?? entry.value)
                                }
                                ForEach(fontStacks, id: \.value) { stack in
                                    Text(stack.name).tag(stack.value)
                                }
                            }
                        }
                    }
                }
                if !sizes.isEmpty {
                    Section("Sizes") {
                        ForEach(sizes) { entry in
                            LabeledContent(entry.label) {
                                HStack(spacing: 4) {
                                    TextField("", value: model.sizeBinding(entry.index), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 64)
                                    Stepper("", value: model.sizeBinding(entry.index), step: model.sizeStep(entry.index))
                                        .labelsHidden()
                                    Text(model.sizeUnit[entry.index] ?? "")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
