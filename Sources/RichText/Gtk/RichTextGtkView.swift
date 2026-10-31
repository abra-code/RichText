// Sources/RichText/Gtk/RichTextGtkView.swift
//
// The Linux view: a whole document in ONE read-only GtkTextView, so it is selectable and copyable as a single
// unit, as the Apple RichText view is. A GTK program places `widget` in its widget tree; the view keeps the
// widget alive (one reference of its own) as long as the object lives.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CRichTextGtk

@MainActor
public final class RichTextGtkView {
    /// The GtkTextView (a `GtkWidget *`).
    public let widget: OpaquePointer

    /// The document shown. Setting it rebuilds the text.
    public var document: RichTextDocument {
        didSet {
            rebuild()
        }
    }

    /// The metrics the document is laid out with. Setting it rebuilds the text.
    public var theme: RichTextTheme {
        didSet {
            rebuild()
        }
    }

    private let textView: UnsafeMutablePointer<GtkTextView>
    private(set) var links: [RichTextGtkLink] = []

    public init(document: RichTextDocument, theme: RichTextTheme = .default) {
        self.document = document
        self.theme = theme
        let made = gtk_text_view_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(made))
        widget = OpaquePointer(made)
        textView = UnsafeMutableRawPointer(made).assumingMemoryBound(to: GtkTextView.self)
        gtk_text_view_set_editable(textView, 0)
        gtk_text_view_set_cursor_visible(textView, 0)
        gtk_text_view_set_wrap_mode(textView, GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(textView, 0)
        rebuild()
    }

    public convenience init(markdown: String, theme: RichTextTheme = .default) {
        self.init(document: RichTextDocument(markdown: markdown), theme: theme)
    }

    /// Shows `markdown`, parsed.
    public func setMarkdown(_ markdown: String) {
        document = RichTextDocument(markdown: markdown)
    }

    // A new buffer each time, so the tags of the old document (and its palette) go with it.
    private func rebuild() {
        let buffer = gtk_text_buffer_new(nil)!
        defer {
            g_object_unref(UnsafeMutableRawPointer(buffer))
        }
        var foreground = GdkRGBA()
        gtk_widget_get_color(UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GtkWidget.self), &foreground)
        let pango = gtk_widget_get_pango_context(UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GtkWidget.self))!
        let builder = RichTextGtkBuilder(buffer: buffer, theme: theme, palette: RichTextGtkPalette(foreground: foreground),
                                         pango: pango)
        builder.build(document)
        links = builder.links
        gtk_text_view_set_buffer(textView, buffer)
    }

    isolated deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
