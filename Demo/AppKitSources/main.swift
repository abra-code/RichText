// Demo/AppKitSources/main.swift
//
// A pure-AppKit host (no SwiftUI) for the TextKit 2 rich-text view, built from the same RichTextAppKit
// factory the SwiftUI representable uses. It doubles as the minimal example of embedding the view in a
// plain AppKit app, and as the harness that isolated the macOS selection bug (content had to be set via
// the text view's textStorage, not NSTextContentStorage.attributedString).

import AppKit
import RichText

private let sampleMarkdown = """
# RichText - AppKit / TextKit 2

One selectable text view, **no SwiftUI**. Select across *everything*, double / triple click, Cmd+A, and
click the [link](https://www.swift.org).

## Lists

- first item
- second item with `code`
- nested:
  - sub one
  - sub two

## Quote

> A block quote, with a bar in the gutter and a **bold** word.

## Code

```swift
// greet someone by name
func greet(_ name: String) -> String {
    let count = 42
    return "Hello, \\(name)!"
}
```

## Table

| Feature  | Status | Notes              |
| -------- | :----: | ------------------ |
| Select   |   ok   | drag, click, Cmd+A |
| Link     |   ok   | click it           |

---

That is all.
"""

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var owner: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let document = RichTextDocument(markdown: sampleMarkdown)
        let (textView, owner) = RichTextAppKit.makeTextKit2View(document)
        self.owner = owner

        // Standard AppKit hosting: the text view as an NSScrollView's documentView.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 720, height: 820)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 820))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "RichText - AppKit (TextKit 2)"
        window.center()
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
