#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// A paste pane: drop an XState machine **definition** (the JSON `definitionJSON()` emits, or an
/// equivalent XState config) into the editor, hit **Load**, and it's parsed and pushed into the
/// bound `InspectorStore` — graph + initial state light up in `MachineInspectorView`.
///
/// Pair it side-by-side with a `MachineInspectorView` over the same store:
/// ```swift
/// HStack {
///     InspectorPasteView(store: store)
///     MachineInspectorView(store: store)
/// }
/// ```
public struct InspectorPasteView: View {
    private let store: InspectorStore
    @Environment(\.inspectorStyle) private var style

    @State private var text: String
    @State private var errorMessage: String?
    @State private var loadedID: String?

    /// - Parameters:
    ///   - store: the inspector store to load definitions into.
    ///   - initialText: optional starting JSON (e.g. a bundled sample).
    public init(store: InspectorStore, initialText: String = "") {
        self.store = store
        _text = State(initialValue: initialText)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(style.divider).frame(height: 1)
            editor
            Rectangle().fill(style.divider).frame(height: 1)
            footer
        }
        .background(style.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(style.accent)
            Text("Machine Definition (XState JSON)")
                .font(.headline)
                .foregroundStyle(style.primaryText)
            Spacer()
            if let loadedID {
                Text("Loaded: \(loadedID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(style.statusActive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.chrome)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(style.monoFont)
            .foregroundStyle(style.primaryText)
            .scrollContentBackground(.hidden)
            .background(style.panelBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste an XState machine definition here…")
                        .font(style.monoFont)
                        .foregroundStyle(style.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                load()
            } label: {
                Label("Load into Inspector", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)

            Button("Clear") {
                text = ""
                errorMessage = nil
            }
            .buttonStyle(.bordered)

            Spacer()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(style.statusError)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.chrome)
    }

    private func load() {
        do {
            loadedID = try store.loadDefinition(json: text)
            errorMessage = nil
        } catch {
            errorMessage = (error as? MachineDefinitionImporter.ImportError)?.description
                ?? error.localizedDescription
            loadedID = nil
        }
    }
}
#endif
