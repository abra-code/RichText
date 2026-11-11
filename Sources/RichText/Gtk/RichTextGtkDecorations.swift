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

/// GtkTextView with a few class functions set, for its view (RichTextGtkView): snapshot_layer paints the decorations
/// below the text, measure and size_allocate size it outside a scrolled window, css_changed follows its style.
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
            parentMeasure = parent?.assumingMemoryBound(to: GtkWidgetClass.self).pointee.measure
            klass.assumingMemoryBound(to: GtkWidgetClass.self).pointee.measure = measure
            parentSizeAllocate = parent?.assumingMemoryBound(to: GtkWidgetClass.self).pointee.size_allocate
            klass.assumingMemoryBound(to: GtkWidgetClass.self).pointee.size_allocate = sizeAllocate
            parentCSSChanged = parent?.assumingMemoryBound(to: GtkWidgetClass.self).pointee.css_changed
            klass.assumingMemoryBound(to: GtkWidgetClass.self).pointee.css_changed = cssChanged
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
        return g_type_register_static(gtk_text_view_get_type(), name, &info, GTypeFlags(rawValue: 0))
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

    // GtkTextView's own measure.
    nonisolated(unsafe) private static var parentMeasure:
        (@convention(c) (UnsafeMutablePointer<GtkWidget>?, GtkOrientation, Int32, UnsafeMutablePointer<Int32>?,
                         UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void)?

    // A wrapping GtkTextView has a natural width of 0, so a window or a stack would give the document none of its
    // own: it asks for the width it takes unwrapped, as the Apple view does. The minimum stays GTK's: it wraps.
    private static let measure: @convention(c) (UnsafeMutablePointer<GtkWidget>?, GtkOrientation, Int32,
                                                UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                                UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void = {
        widget, orientation, forSize, minimum, natural, minimumBaseline, naturalBaseline in
        parentMeasure?(widget, orientation, forSize, minimum, natural, minimumBaseline, naturalBaseline)
        guard orientation == GTK_ORIENTATION_HORIZONTAL, let widget, let natural,
              let data = g_object_get_data(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                                           ownerKey) else {
            return
        }
        // GTK measures on its main thread, the main actor's.
        nonisolated(unsafe) let owner = Unmanaged<Owner>.fromOpaque(data).takeUnretainedValue()
        let width = MainActor.assumeIsolated {
            owner.view?.naturalWidth ?? 0
        }
        natural.pointee = max(natural.pointee, width)
    }

    /// The height of the text as laid out now. GtkTextView's own measure, for gtk_widget_measure caches its answer
    /// until a resize, which is what the caller is deciding on. Whatever width it is asked for, it gives this.
    static func layoutHeight(of widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        // All four: unlike gtk_widget_measure, the class function writes through them without looking.
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var minimumBaseline: Int32 = -1
        var naturalBaseline: Int32 = -1
        parentMeasure?(widget, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, &minimumBaseline, &naturalBaseline)
        return natural
    }

    // GtkTextView's own css_changed.
    nonisolated(unsafe) private static var parentCSSChanged:
        (@convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?) -> Void)?

    // The style the widget has just been given, however it changed. A signal of the style's source, such as
    // libadwaita's notify::dark, comes before this, when the widget still reads the old colors.
    private static let cssChanged: @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?) -> Void = { widget, change in
        parentCSSChanged?(widget, change)
        guard let widget,
              let data = g_object_get_data(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                                           ownerKey) else {
            return
        }
        // GTK validates styles on its main thread.
        nonisolated(unsafe) let owner = Unmanaged<Owner>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.view?.styleChanged()
        }
    }

    // GtkTextView's own size_allocate.
    nonisolated(unsafe) private static var parentSizeAllocate:
        (@convention(c) (UnsafeMutablePointer<GtkWidget>?, Int32, Int32, Int32) -> Void)?

    private static let sizeAllocate: @convention(c) (UnsafeMutablePointer<GtkWidget>?, Int32, Int32, Int32) -> Void = {
        widget, width, height, baseline in
        parentSizeAllocate?(widget, width, height, baseline)
        guard let widget,
              let data = g_object_get_data(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                                           ownerKey) else {
            return
        }
        // GTK allocates on its main thread, the main actor's.
        nonisolated(unsafe) let owner = Unmanaged<Owner>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.view?.settleAfterLayout()
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
        // GTK lays a new text out in the background, and a line not laid out yet has no height: a shape on it, or
        // below it, would be missing or misplaced. GTK does not redraw when it is done, so ask for a redraw then.
        if !linesLaidOut(from: firstShown, to: lastShown, in: buffer) {
            redrawAfterLayout()
        }

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
                guard let left = edges.first, let tableRight = edges.last else {
                    continue
                }
                // A table whose last cell is wider than the view has room for ends at the view's right edge, where
                // that cell wraps.
                let right = min(tableRight, Double(visible.x + visible.width) - 1)
                guard right > left else {
                    continue
                }
                if header {
                    fill(snapshot, x: left, y: top, width: right - left, height: bottom - top, color: palette.codeFill)
                }
                // One-pixel lines on whole pixels, as the Apple renderer strokes them.
                for edge in edges.dropLast() where edge.rounded() < right.rounded() {
                    fill(snapshot, x: edge.rounded(), y: top, width: 1, height: bottom - top, color: palette.separator)
                }
                fill(snapshot, x: right.rounded(), y: top, width: 1, height: bottom - top, color: palette.separator)
                if firstRow {
                    fill(snapshot, x: left, y: top.rounded(), width: right - left, height: 1, color: palette.separator)
                }
                fill(snapshot, x: left, y: bottom.rounded(), width: right - left + 1, height: 1, color: palette.separator)
            }
        }
    }

    // Whether every line from `start` to `end` (character offsets) has its height: every laid-out line has one.
    private func linesLaidOut(from start: Int, to end: Int, in buffer: UnsafeMutablePointer<GtkTextBuffer>) -> Bool {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(start))
        var y: Int32 = 0
        var height: Int32 = 0
        repeat {
            gtk_text_view_get_line_yrange(textViewPointer, &iter, &y, &height)
            if height <= 0 {
                return false
            }
        } while Int(gtk_text_iter_get_offset(&iter)) < end && gtk_text_iter_forward_line(&iter) != 0
        return true
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
