// Sources/RichText/Find/RichTextFindBar.swift
//
// The standalone find UI (layer 3, see RichTextSearch.swift): a bar that edits a RichTextFindController,
// and two modifiers that wire it up - `RichText.find(_:)` binds a document to the controller and paints its
// matches, `View.richTextFindBar(_:)` shows the bar on a container and installs the keyboard shortcuts.
//
//   @StateObject private var find = RichTextFindController()
//   ScrollView { RichText(document).find(find) }
//       .richTextFindBar(find)
//
// A host that has its own search field skips both the bar and the shortcuts and just sets
// `controller.query`; `RichText.find(_:)` still paints. The bar is deliberately plain - a text field, the
// count, previous / next, an options menu and a close button - so it can sit inside any chrome.

import SwiftUI

public struct RichTextFindBar: View {
    @ObservedObject private var controller: RichTextFindController
    @FocusState private var fieldFocused: Bool
    private let placeholder: String

    public init(_ controller: RichTextFindController, placeholder: String = "Find") {
        self.controller = controller
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $controller.query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    controller.next()
                }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            Text(controller.summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                controller.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(controller.ranges.isEmpty)
            .accessibilityLabel("Previous match")
            Button {
                controller.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(controller.ranges.isEmpty)
            .accessibilityLabel("Next match")
            Menu {
                Toggle("Match Case", isOn: $controller.options.caseSensitive)
                Toggle("Whole Words", isOn: $controller.options.wholeWord)
                Toggle("Match Diacritics", isOn: $controller.options.diacriticSensitive)
                Toggle("Regular Expression", isOn: $controller.options.regularExpression)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Find options")
            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        // Focus when a Cmd-F asked for it and no bar has honored that request yet: a repeat Cmd-F while
        // the bar is open puts the reader back in the field, a bar presented by a host (`present(focus:
        // false)`) leaves focus in the host's own field.
        .onAppear {
            focusIfRequested()
        }
        .onChange(of: controller.focusRequests) { _ in
            focusIfRequested()
        }
    }

    private func focusIfRequested() {
        guard controller.focusRequests != controller.focusHonored else {
            return
        }
        controller.markFocusHonored()
        fieldFocused = true
    }
}

public extension RichText {
    /// Paint `controller`'s matches on this document and keep the controller bound to this document's
    /// rendered text. The view that owns the controller (`@StateObject` / `@ObservedObject`) re-renders on
    /// every controller change, which is what re-evaluates this call with fresh highlights.
    ///
    /// Returns `some View`, so apply RichText's own modifiers (`widthBehavior`) BEFORE it. Because that
    /// owning view re-renders per keystroke, build the document's attributed string once and pass it
    /// through `RichText(attributed:)` (as the demo does) rather than re-rendering Markdown in `body`.
    /// When the rendered text changes, the previous ranges may paint for one frame until the controller
    /// re-binds (out-of-range ones are clipped, never fatal).
    func find(_ controller: RichTextFindController) -> some View {
        RichTextFindBinding(controller: controller, text: renderedText, content: findHighlights(controller.highlights))
    }
}

// Binds on appear and whenever the rendered text changes (a re-rendered document), never during a body
// evaluation, so the controller's published state is not mutated mid-update.
private struct RichTextFindBinding<Content: View>: View {
    let controller: RichTextFindController
    let text: String
    let content: Content

    var body: some View {
        content
            .onAppear {
                controller.bind(text: text)
            }
            .onChange(of: text) { newText in
                controller.bind(text: newText)
            }
    }
}

public extension View {
    /// Show `RichTextFindBar` on this container while `controller.isPresented`, inset at `edge`, and
    /// install Cmd-F to present it. Pair with `RichText.find(_:)` on the document inside.
    func richTextFindBar(_ controller: RichTextFindController, edge: VerticalEdge = .top,
                         placeholder: String = "Find") -> some View {
        modifier(RichTextFindBarModifier(controller: controller, edge: edge, placeholder: placeholder))
    }
}

private struct RichTextFindBarModifier: ViewModifier {
    @ObservedObject var controller: RichTextFindController
    let edge: VerticalEdge
    let placeholder: String

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: edge, spacing: 0) {
                if controller.isPresented {
                    RichTextFindBar(controller, placeholder: placeholder)
                }
            }
            .background {
                // An invisible button carries the shortcut; a Button is the one SwiftUI element whose
                // keyboardShortcut works on every platform without a menu.
                Button("Find") {
                    controller.present()
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            }
    }
}
