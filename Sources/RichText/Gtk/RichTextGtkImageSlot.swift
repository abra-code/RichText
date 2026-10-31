// Sources/RichText/Gtk/RichTextGtkImageSlot.swift
//
// One image in the GTK view: the widget at the image's child anchor. It is a placeholder (a framed box with the
// alt text, or for a held remote image the host a click would contact) until the image loads through
// AsyncImageCache, then the image at its display size, capped at the same width as on Apple platforms. Loading
// follows RichTextRemoteImages: automatic, on a click on the placeholder, or never; data: images always load,
// and an image whose scheme is not allow-listed (file:) never does.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import AsyncImageCache
import CRichTextGtk

@MainActor
final class RichTextGtkImageSlot {
    /// The width cap in points, and the decode width in pixels (as RichTextImageLoading on Apple platforms).
    static let maxWidth = 320.0
    static let placeholderSize = (width: 240.0, height: 120.0)

    /// The widget placed at the anchor: a box holding the placeholder or the picture.
    let widget: UnsafeMutablePointer<GtkWidget>
    let alt: String
    let url: URL?
    private(set) var hold: RichTextImageHold = .none
    private(set) var failed = false
    private(set) var loaded: PlatformImage?
    private var approved = false
    private var loading = false        // a load is in flight: starting again (a policy change) waits for it
    private let frame: UnsafeMutablePointer<GtkWidget>
    private let label: UnsafeMutablePointer<GtkWidget>

    init(alt: String, url: URL?) {
        self.alt = alt
        self.url = url
        // A reference of the slot's own on the box and the frame: the frame leaves the box when the image
        // shows, and the box leaves the text view when the document is rebuilt.
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        frame = gtk_frame_new(nil)!
        g_object_ref_sink(UnsafeMutableRawPointer(frame))
        label = gtk_label_new(nil)!
        gtk_label_set_justify(OpaquePointer(label), GTK_JUSTIFY_CENTER)
        gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_add_css_class(label, "dim-label")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_frame_set_child(Self.cast(frame), label)
        gtk_widget_set_size_request(frame, Int32(min(Self.maxWidth, Self.placeholderSize.width)),
                                    Int32(Self.placeholderSize.height))
        gtk_box_append(Self.cast(widget), frame)
        let click = gtk_gesture_click_new()!
        RichTextGtkSignals.onClickReleased(UnsafeMutableRawPointer(click)) { [weak self] _, _ in
            self?.placeholderClicked()
        }
        gtk_widget_add_controller(frame, click)
        refresh()
    }

    /// The request every lookup and load of this image uses, so they share one cache variant.
    var request: ImageRequest? {
        url.map { ImageRequest(url: $0, targetWidth: Self.maxWidth) }
    }

    /// Shows the image if it is cached, else loads it or holds it as `policy` says.
    func start(policy: RichTextRemoteImages) {
        guard loaded == nil, !loading else {
            return
        }
        guard let url, let request, RichTextURLPolicy.allowsImage(url) else {
            // Not an allow-listed scheme (file:, javascript:, a malformed URL): never read.
            failed = true
            refresh()
            return
        }
        if let cached = ImageStore.shared.cachedImage(for: request) {
            show(cached)
            return
        }
        // A click approves the image under .onClick only; it does not outlive a switch to .never (a clicked
        // image whose fetch failed would otherwise be fetched again), as on Apple platforms.
        if RichTextURLPolicy.isRemoteImage(url) {
            switch policy {
            case .never:
                setHold(.off)
                return
            case .onClick:
                if !approved {
                    setHold(.awaitingClick)
                    return
                }
            case .automatic:
                break
            }
        }
        setHold(.none)
        loading = true
        ImageStore.shared.load(request) { [weak self] image in
            // Completions run on the GLib main context's thread, the main thread.
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.loading = false
                if let image {
                    self.show(image)
                } else {
                    self.failed = true
                    self.refresh()
                }
            }
        }
    }

    /// The placeholder's text now.
    var placeholderText: String {
        RichTextImagePlaceholder.label(alt: alt, url: url, failed: failed, hold: hold, action: "Click")
    }

    /// A click on the placeholder (internal for tests).
    func placeholderClicked() {
        guard hold == .awaitingClick else {
            return
        }
        approved = true
        start(policy: .automatic)
    }

    private func setHold(_ newHold: RichTextImageHold) {
        hold = newHold
        refresh()
    }

    private func refresh() {
        gtk_label_set_text(OpaquePointer(label), placeholderText)
        gtk_widget_set_cursor_from_name(frame, hold == .awaitingClick ? "pointer" : nil)
    }

    // The picture in place of the placeholder, at the display size: the natural size up to the width cap.
    private func show(_ image: PlatformImage) {
        guard loaded == nil else {
            return
        }
        loaded = image
        hold = .none
        failed = false
        let picture = gtk_picture_new_for_paintable(image.texture)!
        let width = Double(image.pixelWidth)
        let height = Double(image.pixelHeight)
        let scale = width > Self.maxWidth ? Self.maxWidth / width : 1
        gtk_widget_set_size_request(picture, Int32((width * scale).rounded()), Int32((height * scale).rounded()))
        gtk_picture_set_content_fit(OpaquePointer(picture), GTK_CONTENT_FIT_FILL)
        gtk_picture_set_alternative_text(OpaquePointer(picture), alt.isEmpty ? nil : alt)
        gtk_box_remove(Self.cast(widget), frame)
        gtk_box_append(Self.cast(widget), picture)
    }

    isolated deinit {
        g_object_unref(UnsafeMutableRawPointer(frame))
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    private static func cast<T>(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: T.self)
    }
}
