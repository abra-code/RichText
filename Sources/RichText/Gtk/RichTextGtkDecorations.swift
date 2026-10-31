// Sources/RichText/Gtk/RichTextGtkDecorations.swift
//
// The block decorations painted behind the text, as the Apple renderer paints them (RichTextLayoutFragment):
// rounded code cards, the bar beside a block quote, and the table grid with its shaded header. A GtkTextTag can
// only fill a paragraph's whole width with square corners, so the view is a small GtkTextView subclass whose
// snapshot_layer paints these shapes below the text, from the places the builder recorded and the line
// positions GTK has laid out. The layout itself is the tags'; the shapes take no room.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CRichTextGtk

/// A shape the view paints behind a paragraph: over its lines (character offsets, through its line break),
/// less the spacing above its first line and below its last, which the shape does not cover.
struct RichTextGtkDecoration: Equatable {
    enum Kind: Equatable {
        /// A code block's card, the full width of the text, with rounded corners. It covers the block's lines and
        /// their small spacing, as the paragraph background did.
        case codeCard
        /// The bar beside a block quote's paragraph, at `x` (buffer pixels from the text's left edge).
        case quoteBar(x: Double)
        /// A table row: a line at every column edge, a line below (and above, on the first row), and the header
        /// row shaded.
        case tableRow(edges: [Double], header: Bool, firstRow: Bool)
    }

    let kind: Kind
    let range: Range<Int>
    var spacingAbove: Double = 0
    var spacingBelow: Double = 0
}

// MARK: - The text view subclass

/// GtkTextView with snapshot_layer set: its view (RichTextGtkView) paints the decorations below the text.
enum RichTextGtkDecoratedTextView {
    /// The subclass's GType, registered on first use.
    @MainActor static let type: GType = {
        var info = GTypeInfo()
        info.class_size = guint16(MemoryLayout<GtkTextViewClass>.size)
        info.class_init = { klass, _ in
            guard let klass else {
                return
            }
            let parent = g_type_class_peek_parent(klass).map { UnsafeMutableRawPointer($0) }
            parentSnapshotLayer = parent?.assumingMemoryBound(to: GtkTextViewClass.self).pointee.snapshot_layer
            klass.assumingMemoryBound(to: GtkTextViewClass.self).pointee.snapshot_layer = snapshotLayer
        }
        info.instance_size = guint16(MemoryLayout<GtkTextView>.size)
        // A name no other copy of this module in the process has taken (two adapters may each link one): each
        // copy keeps its own type, whose painting reads only the objects that copy made.
        var name = "RichTextGtkTextView"
        var suffix = 1
        while g_type_from_name(name) != 0 {
            suffix += 1
            name = "RichTextGtkTextView\(suffix)"
        }
        return g_type_register_static(gtk_text_view_get_type(), name, &info, GTypeFlags(0))
    }()

    private static let ownerKey = "richtext-decoration-owner"

    /// A new text view of the subclass, floating as gtk_text_view_new's is.
    @MainActor static func make() -> UnsafeMutablePointer<GtkWidget> {
        let object = g_object_new_with_properties(type, 0, nil, nil)!
        return UnsafeMutableRawPointer(object).assumingMemoryBound(to: GtkWidget.self)
    }

    /// Makes `view` the one that paints `textView`'s decorations. The view is held weakly: the widget may
    /// outlive it in a window.
    @MainActor static func paint(_ textView: UnsafeMutablePointer<GtkTextView>, by view: RichTextGtkView) {
        let owner = Unmanaged.passRetained(Owner(view)).toOpaque()
        g_object_set_data_full(UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GObject.self), ownerKey, owner) { data in
            if let data {
                Unmanaged<Owner>.fromOpaque(data).release()
            }
        }
    }

    private final class Owner {
        weak var view: RichTextGtkView?
        init(_ view: RichTextGtkView) {
            self.view = view
        }
    }

    // GtkTextView's own snapshot_layer, if a class above sets one (GtkTextView itself does not).
    nonisolated(unsafe) private static var parentSnapshotLayer:
        (@convention(c) (UnsafeMutablePointer<GtkTextView>?, GtkTextViewLayer, OpaquePointer?) -> Void)?

    private static let snapshotLayer: @convention(c) (UnsafeMutablePointer<GtkTextView>?, GtkTextViewLayer,
                                                      OpaquePointer?) -> Void = { textView, layer, snapshot in
        parentSnapshotLayer?(textView, layer, snapshot)
        guard layer == GTK_TEXT_VIEW_LAYER_BELOW_TEXT, let textView, let snapshot,
              let data = g_object_get_data(UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GObject.self),
                                           ownerKey) else {
            return
        }
        // GTK draws on its main thread, the main actor's.
        nonisolated(unsafe) let target = (Unmanaged<Owner>.fromOpaque(data).takeUnretainedValue(), snapshot)
        MainActor.assumeIsolated {
            target.0.view?.paintDecorations(target.1)
        }
    }
}

// MARK: - Painting

extension RichTextGtkView {
    // Paints the decorations of the lines in view, in buffer coordinates (the layer's snapshot is translated so).
    func paintDecorations(_ snapshot: OpaquePointer) {
        guard let builder, !builder.decorations.isEmpty, let buffer = gtk_text_view_get_buffer(textViewPointer) else {
            return
        }
        let palette = builder.palette
        var visible = GdkRectangle()
        gtk_text_view_get_visible_rect(textViewPointer, &visible)
        // The character range on screen, so a long document paints only what shows. It starts one pixel above
        // the view: a table row's bottom line lies on the next line's first pixel row.
        var iter = GtkTextIter()
        var lineTop: Int32 = 0
        gtk_text_view_get_line_at_y(textViewPointer, &iter, visible.y - 1, &lineTop)
        let firstShown = Int(gtk_text_iter_get_offset(&iter))
        gtk_text_view_get_line_at_y(textViewPointer, &iter, visible.y + visible.height, &lineTop)
        gtk_text_iter_forward_line(&iter)
        let lastShown = Int(gtk_text_iter_get_offset(&iter))

        for decoration in builder.decorations
        where decoration.range.upperBound > firstShown && decoration.range.lowerBound <= lastShown {
            let (top, bottom) = verticalExtent(of: decoration, in: buffer)
            guard bottom > top else {
                continue
            }
            switch decoration.kind {
            case .codeCard:
                fill(snapshot, x: Double(visible.x) + 1, y: top, width: Double(visible.width) - 2, height: bottom - top,
                     radius: Double(theme.codeCornerRadius), color: palette.codeFill)
            case .quoteBar(let x):
                fill(snapshot, x: x, y: top, width: 3, height: bottom - top, radius: 1.5, color: palette.separator)
            case .tableRow(let edges, let header, let firstRow):
                guard let left = edges.first, let right = edges.last else {
                    continue
                }
                if header {
                    fill(snapshot, x: left, y: top, width: right - left, height: bottom - top, color: palette.codeFill)
                }
                // One-pixel lines on whole pixels, as the Apple renderer strokes them.
                for edge in edges {
                    fill(snapshot, x: edge.rounded(), y: top, width: 1, height: bottom - top, color: palette.separator)
                }
                if firstRow {
                    fill(snapshot, x: left, y: top.rounded(), width: right - left, height: 1, color: palette.separator)
                }
                fill(snapshot, x: left, y: bottom.rounded(), width: right - left + 1, height: 1, color: palette.separator)
            }
        }
    }

    // From the top of the paragraph's first line to the bottom of its last, less the spacing outside the shape.
    private func verticalExtent(of decoration: RichTextGtkDecoration,
                                in buffer: UnsafeMutablePointer<GtkTextBuffer>) -> (Double, Double) {
        var iter = GtkTextIter()
        var y: Int32 = 0
        var height: Int32 = 0
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(decoration.range.lowerBound))
        gtk_text_view_get_line_yrange(textViewPointer, &iter, &y, &height)
        let top = Double(y) + decoration.spacingAbove
        // The paragraph's last character is its line break (the document's last paragraph has none: the offset
        // then falls at the end, on the same line).
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(max(decoration.range.lowerBound, decoration.range.upperBound - 1)))
        gtk_text_view_get_line_yrange(textViewPointer, &iter, &y, &height)
        return (top, Double(y + height) - decoration.spacingBelow)
    }

    private func fill(_ snapshot: OpaquePointer, x: Double, y: Double, width: Double, height: Double,
                      radius: Double = 0, color: GdkRGBA) {
        var rect = graphene_rect_t(origin: graphene_point_t(x: Float(x), y: Float(y)),
                                   size: graphene_size_t(width: Float(width), height: Float(height)))
        var color = color
        guard radius > 0 else {
            gtk_snapshot_append_color(snapshot, &color, &rect)
            return
        }
        var rounded = GskRoundedRect()
        gsk_rounded_rect_init_from_rect(&rounded, &rect, Float(radius))
        gtk_snapshot_push_rounded_clip(snapshot, &rounded)
        gtk_snapshot_append_color(snapshot, &color, &rect)
        gtk_snapshot_pop(snapshot)
    }
}
