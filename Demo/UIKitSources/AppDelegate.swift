// Demo/UIKitSources/AppDelegate.swift
//
// A pure-UIKit host (no SwiftUI) for the TextKit 2 rich-text view, built from the same RichTextUIKit
// factory the SwiftUI representable uses - the parity counterpart of RichTextAppKitDemo. It is the minimal
// example of embedding the view in a plain UIKit app, and a place to test selection / links / Dynamic Type
// without SwiftUI involved.

import UIKit
import RichText

private let sampleMarkdown = """
# RichText - UIKit / TextKit 2

One selectable text view, **no SwiftUI**. Select across *everything*, and tap the [link](https://www.swift.org).

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
| Select   |   ok   | press-hold, drag   |
| Link     |   ok   | tap it             |

---

That is all.
"""

final class RichTextDemoViewController: UIViewController {
    private var owner: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let document = RichTextDocument(markdown: sampleMarkdown)
        let (textView, owner) = RichTextUIKit.makeTextKit2View(document)
        self.owner = owner

        // A scrolling host (the SwiftUI representable keeps it non-scrolling + self-sizing instead).
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RichTextDemoViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
