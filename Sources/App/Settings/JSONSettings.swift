import Core
import SwiftUI

extension JSONValue {
    func text(_ key: String) -> String {
        if case .string(let s)? = self[key] { s } else { "" }
    }

    func flag(_ key: String) -> Bool {
        if case .bool(let b)? = self[key] { b } else { false }
    }

    /// Settings are `.object`; an empty string removes the key.
    mutating func set(_ key: String, text: String) {
        guard case .object(var o) = self else { return }
        o[key] = text.isEmpty ? nil : .string(text)
        self = .object(o)
    }

    mutating func set(_ key: String, flag: Bool) {
        guard case .object(var o) = self else { return }
        o[key] = .bool(flag)
        self = .object(o)
    }
}

/// Edits a draft and writes it back on Return or when focus leaves, so each keystroke does not round-trip through the engine.
struct CommitField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onSubmit { commit(text) }
            .onChange(of: focused) { if !focused { commit(text) } }
            .onChange(of: value) { if !focused { text = value } }
            .onAppear { text = value }
    }
}

@MainActor
func chooseFile(directories: Bool = false) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !directories
    panel.canChooseDirectories = directories
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url?.path : nil
}
