import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
enum Panel {
    static func open(directories: Bool = false, types: [UTType] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(name: String, types: [UTType] = []) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
