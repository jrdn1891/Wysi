import SwiftUI

@MainActor
final class FindModel: ObservableObject {
    @Published var text = ""
    var onSearch: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
}

struct FindBar: View {
    @ObservedObject var model: FindModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $model.text)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 220)
                .onSubmit { model.onSearch(model.text, false) }
                .onExitCommand { model.onClose() }
                .onChange(of: model.text) { _, text in
                    model.onSearch(text, false)
                }
            Button { model.onSearch(model.text, true) } label: { Image(systemName: "chevron.up") }
            Button { model.onSearch(model.text, false) } label: { Image(systemName: "chevron.down") }
            Button("Done") { model.onClose() }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }
}
