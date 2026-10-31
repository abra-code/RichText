// Demo/Linux/Sources/RichTextDemo/main.swift
//
// A small GTK 4 program to try RichText on Linux: one document in a RichTextGtkView under a header bar that
// picks the document (a sample, local and remote images, or one of the Markdown fixtures the tests use), sets
// the remote-image policy, shows the find bar (also Ctrl+F) and copies the document as rich text (HTML and
// Markdown).

import Foundation
import CDemoGtk
import RichText

// MARK: - Documents

let sampleMarkdown = """
# RichText

A whole document rendered in **one** selectable text view - select and copy across *everything*, including the
table.

## Inline

`inline code`, **bold**, *italic*, ~~strikethrough~~, and an explicit [link](https://www.swift.org).

A bare URL autolinks too: visit https://swift.org or www.apple.com for more.

## Image

An image loads asynchronously (placeholder first, then the picture):

![Swift logo](https://www.swift.org/apple-touch-icon.png)

## Lists

- first item
- second item with `code`
- nested:
  - sub one
  - sub two

1. ordered one
2. ordered two

## Quote

> A block quote, with a **bold** word.

## Code

```swift
// Greet someone by name.
func greet(_ name: String) -> String {
    let count = 42
    return "Hello, \\(name)!"
}
```

## Table

| Feature  | Status | Notes                               |
| -------- | :----: | ----------------------------------- |
| Headings |   ok   | scaled and bold                     |
| Code     |   ok   | a card with syntax highlighting     |
| Tables   |   ok   | tab stops, content-sized columns    |

---

That is all.
"""

// A message on standard error.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// A folder the demo reads: beside the program when it was copied elsewhere with it, otherwise found from this
// source file's place in the repository (`inRepository` is relative to the repository's root).
func resourceFolder(besideProgram name: String, inRepository path: String) -> URL {
    let besideProgram = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent(name, isDirectory: true)
    let inRepository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Demo/Linux
        .deletingLastPathComponent().deletingLastPathComponent()                               // repository
        .appendingPathComponent(path, isDirectory: true)
    var isFolder: ObjCBool = false
    return besideProgram.flatMap {
        FileManager.default.fileExists(atPath: $0.path, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil
    } ?? inRepository
}

// A document the menu offers: its name, its Markdown, and where it lives (relative image paths resolve against
// that place).
struct Document {
    let name: String
    let markdown: String
    var baseURL: URL?
}

// Images that load: two local files beside the demo, by relative paths, and two remote pictures.
func imagesDocument() -> Document {
    // The folder that holds Images/, as if this document were a file in it.
    let folder = resourceFolder(besideProgram: "Images", inRepository: "Demo/Linux/Images").deletingLastPathComponent()
    let markdown = """
    # Images

    ## Local

    Two image files shipped with the demo, named by paths relative to the document's folder \
    (`Images/actionui.png`). Showing them sends nothing anywhere, so they always show, whatever the Remote Images \
    menu says.

    The ActionUI icon:

    ![ActionUI icon](Images/actionui.png)

    The abracode cube, with transparency, so the page's background shows through it in light and dark:

    ![abracode cube](Images/abracode.png)

    ## Remote

    Fetched through AsyncImageCache (cached in memory and on disk) when the Remote Images menu allows it: \
    automatically, on a click on the placeholder, or never.

    A photo from picsum.photos:

    ![A photo from picsum.photos](https://picsum.photos/seed/richtext/800/450)

    The Swift logo from swift.org:

    ![Swift logo](https://www.swift.org/apple-touch-icon.png)

    For images that fail on purpose and their fallbacks, open the images-broken document.
    """
    return Document(name: "Images", markdown: markdown, baseURL: folder)
}

// The shared Markdown fixtures (Fixtures/markdown).
func fixtureDocuments() -> [Document] {
    let folder = resourceFolder(besideProgram: "Fixtures/markdown", inRepository: "Fixtures/markdown")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
        guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
            return nil
        }
        return Document(name: String(name.dropLast(3)), markdown: text, baseURL: folder)
    }
}

let documents = [Document(name: "Sample", markdown: sampleMarkdown), imagesDocument()] + fixtureDocuments()

// MARK: - Signals

// A Swift closure as a signal handler's user data, released by GLib with the handler.
final class Handler {
    let run: () -> Void
    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

let releaseHandler: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data {
        Unmanaged<Handler>.fromOpaque(data).release()
    }
}

// (instance, user data) and (instance, one pointer argument, user data) signal shapes.
let plainTrampoline: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
    if let data {
        Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().run()
    }
}
let notifyTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, _, data in
    if let data {
        Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().run()
    }
}

@MainActor
func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, notify: Bool = false, _ run: @escaping () -> Void) {
    let data = Unmanaged.passRetained(Handler(run)).toOpaque()
    let trampoline = notify ? unsafeBitCast(notifyTrampoline, to: GCallback.self)
                            : unsafeBitCast(plainTrampoline, to: GCallback.self)
    if g_signal_connect_data(instance, signal, trampoline, data, releaseHandler, GConnectFlags(0)) == 0 {
        Unmanaged<Handler>.fromOpaque(data).release()
    }
}

func widget(_ pointer: OpaquePointer) -> UnsafeMutablePointer<GtkWidget> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
}

func cast<T>(_ pointer: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}

// A drop-down of strings.
func dropDown(_ items: [String]) -> UnsafeMutablePointer<GtkWidget> {
    var strings = items.map { strdup($0) }
    defer {
        strings.forEach { free($0) }
    }
    strings.append(nil)
    let list = strings.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
            gtk_string_list_new($0)
        }
    }
    return gtk_drop_down_new(list, nil)!
}

// MARK: - Window

// The value after a command-line option, as in `--screenshot <png>`.
func optionValue(_ option: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

let screenshotPath = optionValue("--screenshot")
// The document to open first, by its name in the menu (`--document tables`); the sample otherwise.
let firstDocument = optionValue("--document")

// Kept for the program's life.
nonisolated(unsafe) var view: RichTextGtkView!
nonisolated(unsafe) var find: RichTextGtkFindController!
nonisolated(unsafe) var bar: RichTextGtkFindBar!

@MainActor
func buildWindow(_ application: UnsafeMutablePointer<GtkApplication>) {
    let window = gtk_application_window_new(application)!
    gtk_window_set_title(cast(window), "RichText Demo")
    gtk_window_set_default_size(cast(window), 760, 900)

    view = RichTextGtkView(markdown: sampleMarkdown)
    find = RichTextGtkFindController()
    find.bind(view: view)
    bar = RichTextGtkFindBar(find)

    // Header bar: the document, the remote-image policy, find, copy.
    let header = gtk_header_bar_new()!
    let picker = dropDown(documents.map(\.name))
    gtk_widget_set_tooltip_text(picker, "Document")
    connect(UnsafeMutableRawPointer(picker), "notify::selected", notify: true) {
        let index = Int(gtk_drop_down_get_selected(OpaquePointer(picker)))
        if documents.indices.contains(index) {
            MainActor.assumeIsolated { view.setMarkdown(documents[index].markdown, baseURL: documents[index].baseURL) }
        }
    }
    if let firstDocument {
        if let index = documents.firstIndex(where: { $0.name == firstDocument }) {
            gtk_drop_down_set_selected(OpaquePointer(picker), guint(index))
        } else {
            warn("no document named \(firstDocument); the names are \(documents.map(\.name).joined(separator: ", "))")
        }
    }
    let policies: [RichTextRemoteImages] = [.automatic, .onClick, .never]
    let policy = dropDown(["Remote Images: Automatic", "Remote Images: On Click", "Remote Images: Never"])
    connect(UnsafeMutableRawPointer(policy), "notify::selected", notify: true) {
        let index = Int(gtk_drop_down_get_selected(OpaquePointer(policy)))
        if policies.indices.contains(index) {
            MainActor.assumeIsolated { view.remoteImages = policies[index] }
        }
    }
    let findButton = gtk_button_new_from_icon_name("edit-find-symbolic")!
    gtk_widget_set_tooltip_text(findButton, "Find (Ctrl+F)")
    connect(UnsafeMutableRawPointer(findButton), "clicked") {
        MainActor.assumeIsolated { find.present() }
    }
    let copy = gtk_button_new_with_label("Copy as Rich Text")!
    gtk_widget_set_tooltip_text(copy, "Copy the document as HTML and Markdown")
    connect(UnsafeMutableRawPointer(copy), "clicked") {
        MainActor.assumeIsolated { RichTextGtkClipboard.write(view.document) }
    }
    gtk_header_bar_pack_start(OpaquePointer(header), picker)
    gtk_header_bar_pack_start(OpaquePointer(header), policy)
    gtk_header_bar_pack_end(OpaquePointer(header), copy)
    gtk_header_bar_pack_end(OpaquePointer(header), findButton)
    gtk_window_set_titlebar(cast(window), header)

    // The find bar above the scrolled document. The text view is the scrolled window's own child (it scrolls
    // itself): inside a box, find could not scroll to a match and a click made the box's viewport jump.
    let text = widget(view.widget)
    // Side padding as the widget's margins (the document's indents replace the text view's left and right
    // margins); top and bottom padding as the text view's own margins, which scroll with the text.
    gtk_widget_set_margin_start(text, 20)
    gtk_widget_set_margin_end(text, 20)
    gtk_text_view_set_top_margin(cast(text), 16)
    gtk_text_view_set_bottom_margin(cast(text), 16)
    let scrolled = gtk_scrolled_window_new()!
    // The padding on the document's own background.
    gtk_widget_add_css_class(scrolled, "view")
    gtk_scrolled_window_set_child(OpaquePointer(scrolled), text)
    gtk_widget_set_vexpand(scrolled, 1)
    let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    gtk_box_append(cast(column), widget(bar.widget))
    gtk_box_append(cast(column), scrolled)
    gtk_window_set_child(cast(window), column)
    // On the window, not the column: the shortcuts then work with the focus in the header bar or nowhere yet.
    bar.installShortcuts(on: OpaquePointer(window))

    gtk_window_present(cast(window))

    if let screenshotPath {
        // After the window has drawn and the images had a moment to load: save it, then quit.
        let data = Unmanaged.passRetained(Handler {
            saveScreenshot(window, to: screenshotPath)
            g_application_quit(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self))
        }).toOpaque()
        g_timeout_add_full(G_PRIORITY_DEFAULT, 2000, { data in
            if let data {
                Unmanaged<Handler>.fromOpaque(data).takeRetainedValue().run()
            }
            return 0
        }, data, nil)
    }
}

// The window as its own renderer draws it.
func saveScreenshot(_ window: UnsafeMutablePointer<GtkWidget>, to path: String) {
    let width = gtk_widget_get_width(window)
    let height = gtk_widget_get_height(window)
    guard width > 0, height > 0, let renderer = gtk_native_get_renderer(OpaquePointer(window)),
          let paintable = gtk_widget_paintable_new(window), let snapshot = gtk_snapshot_new() else {
        print("screenshot failed: the window is not drawn")
        return
    }
    gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
    guard let node = gtk_snapshot_free_to_node(snapshot) else {
        print("screenshot failed: nothing drawn")
        return
    }
    var viewport = graphene_rect_t(origin: graphene_point_t(x: 0, y: 0),
                                   size: graphene_size_t(width: Float(width), height: Float(height)))
    let texture = gsk_renderer_render_texture(renderer, node, &viewport)
    let saved = texture.map { gdk_texture_save_to_png($0, path) != 0 } ?? false
    print(saved ? "saved \(path)" : "screenshot failed: cannot write \(path)")
}

// MARK: - Main

let application = gtk_application_new("com.abracode.RichTextDemo", G_APPLICATION_NON_UNIQUE)!
connect(UnsafeMutableRawPointer(application), "activate") {
    MainActor.assumeIsolated { buildWindow(application) }
}
// GTK reads its own command-line options; the demo's (--document, --screenshot) are not passed to it.
let status = g_application_run(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self), 0, nil)
exit(status)
