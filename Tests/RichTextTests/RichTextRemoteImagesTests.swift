// Tests/RichTextTests/RichTextRemoteImagesTests.swift
//
// RichTextRemoteImages: under .onClick and .never a remote (http / https) image is held with a placeholder and
// never fetched until the user clicks it (.onClick only); data: images load in every mode; .automatic fetches
// at once, as before. Fetching is the thing that matters, so the assertions are about RichTextImageLoading's
// in-flight set: a URL on it has been handed to the network.
//
// Every remote URL is on the .invalid top-level domain, which never resolves, and is unique per test, so no
// test can reach a real host and the process-wide cache and in-flight set cannot carry state between tests.

import XCTest
@testable import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class RichTextRemoteImagesTests: XCTestCase {

    private func remoteURL(_ name: String = #function) -> URL {
        return URL(string: "https://richtext-remote-images.invalid/\(name)-\(UUID().uuidString).png")!
    }

    private func content(_ attachments: [RichTextImageAttachment]) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: "before ", attributes: [.font: RTVFont.systemFont(ofSize: 13)])
        for attachment in attachments {
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " after", attributes: [.font: RTVFont.systemFont(ofSize: 13)]))
        }
        return text
    }

    // MARK: - Policy

    func testRemoteMeansHTTPOrHTTPS() {
        XCTAssertTrue(RichTextURLPolicy.isRemoteImage(URL(string: "https://x.test/y.png")!))
        XCTAssertTrue(RichTextURLPolicy.isRemoteImage(URL(string: "HTTP://x.test/y.png")!), "schemes are case-insensitive")
        XCTAssertFalse(RichTextURLPolicy.isRemoteImage(URL(string: "data:image/png;base64,AAAA")!))
        XCTAssertFalse(RichTextURLPolicy.isRemoteImage(URL(string: "file:///etc/passwd")!))
    }

    // MARK: - Loading pass

    func testOnClickHoldsARemoteImageWithoutFetchingIt() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        var reloads = 0
        RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: .onClick) { reloads += 1 }
        XCTAssertEqual(attachment.hold, .awaitingClick)
        XCTAssertFalse(RichTextImageLoading.isFetching(url), "a held image must not be fetched")
        XCTAssertEqual(reloads, 1, "the placeholder changed, so the view is asked to redraw once")
    }

    func testNeverHoldsARemoteImageWithoutFetchingIt() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: .never) {}
        XCTAssertEqual(attachment.hold, .off)
        XCTAssertFalse(RichTextImageLoading.isFetching(url))
    }

    func testAutomaticFetchesARemoteImageAtOnce() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: .automatic) {}
        XCTAssertEqual(attachment.hold, .none)
        XCTAssertTrue(RichTextImageLoading.isFetching(url), "the default fetches as soon as the document renders")
    }

    func testTheDefaultIsAutomatic() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        RichTextImageLoading.startLoading(in: content([attachment])) {}
        XCTAssertTrue(RichTextImageLoading.isFetching(url), "callers that pass no policy keep the old behavior")
    }

    func testADataImageIsNeverHeld() {
        // A data: image carries its bytes in the document; showing it sends nothing anywhere.
        for policy in [RichTextRemoteImages.onClick, .never] {
            let url = URL(string: "data:image/png;base64,\(policy.rawValue)\(UUID().uuidString.prefix(8))AAAA")!
            let attachment = RichTextImageAttachment(alt: "inline", url: url)
            RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: policy) {}
            XCTAssertEqual(attachment.hold, .none, "\(policy)")
            XCTAssertTrue(RichTextImageLoading.isFetching(url) || attachment.loadedImage != nil, "\(policy)")
        }
    }

    func testAFileImageIsNeitherHeldNorRead() {
        let url = URL(string: "file:///etc/passwd")!
        let attachment = RichTextImageAttachment(alt: "local", url: url)
        RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: .onClick) {}
        XCTAssertEqual(attachment.hold, .none, "file: is refused outright, not offered for a click")
        XCTAssertFalse(RichTextImageLoading.isFetching(url))
    }

    // MARK: - Click

    func testAClickFetchesTheHeldImage() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        let text = content([attachment])
        RichTextImageLoading.startLoading(in: text, remoteImages: .onClick) {}
        var reloads = 0
        XCTAssertTrue(RichTextImageLoading.loadOnClick(attachment, in: text) { reloads += 1 })
        XCTAssertEqual(attachment.hold, .none, "the placeholder goes back to loading")
        XCTAssertTrue(attachment.approved)
        XCTAssertTrue(RichTextImageLoading.isFetching(url))
        XCTAssertEqual(reloads, 1, "redrawn at once to show that it is loading")
    }

    func testAClickedImageIsNotHeldAgain() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        let text = content([attachment])
        RichTextImageLoading.startLoading(in: text, remoteImages: .onClick) {}
        RichTextImageLoading.loadOnClick(attachment, in: text) {}
        RichTextImageLoading.startLoading(in: text, remoteImages: .onClick) {}
        XCTAssertEqual(attachment.hold, .none, "a later loading pass must not take the user's click back")
    }

    func testAClickOnlyActsOnAnImageWaitingForIt() {
        let offURL = remoteURL()
        let off = RichTextImageAttachment(alt: "chart", url: offURL)
        RichTextImageLoading.startLoading(in: content([off]), remoteImages: .never) {}
        XCTAssertFalse(RichTextImageLoading.loadOnClick(off, in: content([off])) {}, "under .never a click does nothing")
        XCTAssertEqual(off.hold, .off)
        XCTAssertFalse(RichTextImageLoading.isFetching(offURL))

        let plain = RichTextImageAttachment(alt: "chart", url: remoteURL("plain"))
        XCTAssertFalse(RichTextImageLoading.loadOnClick(plain, in: content([plain])) {}, "nothing held, nothing to do")
        XCTAssertFalse(plain.approved)
    }

    func testOnlyTheClickedImageIsFetched() {
        let first = remoteURL("first")
        let second = remoteURL("second")
        let a = RichTextImageAttachment(alt: "a", url: first)
        let b = RichTextImageAttachment(alt: "b", url: second)
        let text = content([a, b])
        RichTextImageLoading.startLoading(in: text, remoteImages: .onClick) {}
        RichTextImageLoading.loadOnClick(a, in: text) {}
        XCTAssertTrue(RichTextImageLoading.isFetching(first))
        XCTAssertFalse(RichTextImageLoading.isFetching(second), "one click approves one image, not the document")
        XCTAssertEqual(b.hold, .awaitingClick)
    }

    func testSwitchingToAutomaticFetchesTheHeldImages() {
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        let text = content([attachment])
        RichTextImageLoading.startLoading(in: text, remoteImages: .onClick) {}
        RichTextImageLoading.startLoading(in: text, remoteImages: .automatic) {}
        XCTAssertEqual(attachment.hold, .none)
        XCTAssertTrue(RichTextImageLoading.isFetching(url))
    }

    func testAClickDoesNotOutliveASwitchToNever() {
        // Clicked under .onClick, then its fetch failed (the image is still not loaded): .never must not fetch
        // it again.
        let url = remoteURL()
        let attachment = RichTextImageAttachment(alt: "chart", url: url)
        attachment.approved = true
        RichTextImageLoading.startLoading(in: content([attachment]), remoteImages: .never) {}
        XCTAssertEqual(attachment.hold, .off)
        XCTAssertFalse(RichTextImageLoading.isFetching(url), "under .never nothing is fetched, clicked or not")
    }

    // MARK: - The same image in several documents at once

    #if canImport(AppKit)
    // A small PNG whose pixel color is random, as a data: URL, so no other test (and no earlier run's disk
    // cache) has this image.
    private func uniqueDataImageURL() -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(NSColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1),
                     atX: 0, y: 0)
        let png = rep.representation(using: .png, properties: [:])!
        return URL(string: "data:image/png;base64," + png.base64EncodedString())!
    }

    func testDocumentsSharingAnImageAllShowItWhenItArrives() async {
        // The second document finds the fetch already running and does not start another; it must still be
        // told when that fetch ends, or it keeps its placeholder until the view is rebuilt.
        let url = uniqueDataImageURL()
        let first = RichTextImageAttachment(alt: "first", url: url)
        let second = RichTextImageAttachment(alt: "second", url: url)
        var secondReloads = 0
        RichTextImageLoading.startLoading(in: content([first]), remoteImages: .automatic) {}
        RichTextImageLoading.startLoading(in: content([second]), remoteImages: .automatic) { secondReloads += 1 }
        let deadline = Date().addingTimeInterval(5)
        while (first.loadedImage == nil || second.loadedImage == nil) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(first.loadedImage)
        XCTAssertNotNil(second.loadedImage, "the document that waited on the running fetch shows the image too")
        XCTAssertEqual(secondReloads, 1, "and its view was asked to redraw")
        XCTAssertFalse(RichTextImageLoading.isFetching(url))
    }

    func testADocumentThatFindsTheImageCachedBeforeTheFetchEndsIsStillTold() async {
        // The store caches the image off the main thread and only then tells the fetch, on the main thread. A
        // document whose loading pass looks in between finds the image cached, after its own applyCached ran:
        // it must still wait on the fetch, or nothing ever applies the image to it.
        let url = uniqueDataImageURL()
        let first = RichTextImageAttachment(alt: "first", url: url)
        let second = RichTextImageAttachment(alt: "second", url: url)
        RichTextImageLoading.startLoading(in: content([first]), remoteImages: .automatic) {}
        let text = ImageArrivesMidPass(content([second])) {
            let deadline = Date().addingTimeInterval(5)
            while RichTextImageLoading.cachedImage(for: url) == nil && Date() < deadline {
                usleep(1_000)
            }
        }
        var secondReloads = 0
        RichTextImageLoading.startLoading(in: text, remoteImages: .automatic) { secondReloads += 1 }
        let deadline = Date().addingTimeInterval(5)
        while (first.loadedImage == nil || second.loadedImage == nil) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(first.loadedImage)
        XCTAssertNotNil(second.loadedImage, "the document that found the image cached mid-fetch shows it too")
        XCTAssertEqual(secondReloads, 1)
    }
    #endif

    func testDocumentsSharingAFailedImageAllSayItIsUnavailable() async {
        let url = remoteURL()
        let first = RichTextImageAttachment(alt: "first", url: url)
        let second = RichTextImageAttachment(alt: "second", url: url)
        RichTextImageLoading.startLoading(in: content([first]), remoteImages: .automatic) {}
        RichTextImageLoading.startLoading(in: content([second]), remoteImages: .automatic) {}
        let deadline = Date().addingTimeInterval(20)
        while (!first.hasFailed || !second.hasFailed) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(first.hasFailed)
        XCTAssertTrue(second.hasFailed, "a document waiting on a fetch that fails says so, not \"loading\" forever")
    }

    // MARK: - Placeholder

    func testTheHeldPlaceholderNamesTheHost() {
        let url = URL(string: "https://collector.example/pixel.png?d=secret")!
        #if canImport(AppKit)
        let action = "Click"
        #else
        let action = "Tap"
        #endif
        XCTAssertEqual(RichTextImageAttachment.placeholderLabel(alt: "chart", url: url, failed: false, hold: .awaitingClick),
                       "chart\n\(action) to load from collector.example")
        XCTAssertEqual(RichTextImageAttachment.placeholderLabel(alt: "", url: url, failed: false, hold: .awaitingClick),
                       "Image\n\(action) to load from collector.example")
        XCTAssertEqual(RichTextImageAttachment.placeholderLabel(alt: "chart", url: url, failed: false, hold: .off),
                       "chart\nNot loaded from collector.example: remote images are off")
        XCTAssertEqual(RichTextImageAttachment.placeholderLabel(alt: "chart", url: url, failed: false, hold: .none), "chart")
        XCTAssertEqual(RichTextImageAttachment.placeholderLabel(alt: "chart", url: url, failed: true, hold: .none),
                       "chart (unavailable)")
    }

    func testTheHostIsShownAsWrittenNotDecoded() {
        // A decoded host would show an escaped "/" as a path separator: "apple.com/..." for a request that goes
        // to evil.example.
        guard let url = URL(string: "https://apple.com%2Fimages.evil.example/x.png") else {
            return XCTFail("sanity: the URL parses")
        }
        let label = RichTextImageAttachment.placeholderLabel(alt: "", url: url, failed: false, hold: .awaitingClick)
        XCTAssertTrue(label.hasSuffix("load from apple.com%2Fimages.evil.example"), label)
    }

    // MARK: - Hit testing and the click hook (macOS)

    #if canImport(AppKit)
    private func hostInWindow(_ textView: NSTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(textView)
        return window
    }

    private func makeTK1View(_ text: NSAttributedString) -> RichTextTopAlignedTextView {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = RichTextLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let textView = RichTextTopAlignedTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContainerInset = .zero
        layoutManager.ensureLayout(for: container)
        return textView
    }

    // The center of the character at `index`, in the text view's coordinates, from TextKit 1's own geometry.
    private func centerTK1(of index: Int, in textView: NSTextView) -> CGPoint {
        let layoutManager = textView.layoutManager!
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        let origin = textView.textContainerOrigin
        return CGPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in textView: NSTextView,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let inWindow = textView.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    // A press on the held image and its release at `releasePoint`. The release is queued first: the view's
    // tracking loop takes it from the event queue. Only presses that land on a held image are sent here - any
    // other press goes to NSTextView's own mouseDown, whose tracking loop would wait on the real mouse.
    private func click(at point: CGPoint, releasedAt releasePoint: CGPoint? = nil, in textView: NSTextView) {
        _ = NSApplication.shared
        textView.window!.postEvent(mouseEvent(.leftMouseUp, at: releasePoint ?? point, in: textView), atStart: false)
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: textView))
    }

    func testTK1FindsTheHeldImageUnderAClickAndNothingElse() {
        let attachment = RichTextImageAttachment(alt: "chart", url: remoteURL())
        let text = content([attachment])
        let textView = makeTK1View(text)
        let window = hostInWindow(textView)
        defer { window.close() }
        RichTextImageLoading.startLoading(in: textView.textStorage!, remoteImages: .onClick) {}
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)

        let onImage = centerTK1(of: 7, in: textView)
        XCTAssertTrue(RichTextImageLoading.heldAttachment(at: onImage, in: textView) === attachment)
        let onWord = centerTK1(of: 1, in: textView)
        XCTAssertNil(RichTextImageLoading.heldAttachment(at: onWord, in: textView), "a click on the text is not a click on the image")

        RichTextImageLoading.loadOnClick(attachment, in: textView.textStorage!) {}
        XCTAssertNil(RichTextImageLoading.heldAttachment(at: onImage, in: textView), "once loading, it is no longer held")
    }

    func testTK1MouseDownOnAHeldImageReachesTheHook() {
        let attachment = RichTextImageAttachment(alt: "chart", url: remoteURL())
        let textView = makeTK1View(content([attachment]))
        let window = hostInWindow(textView)
        defer { window.close() }
        RichTextImageLoading.startLoading(in: textView.textStorage!, remoteImages: .onClick) {}
        var clicked: RichTextImageAttachment?
        textView.onHeldImageClick = { clicked = $0 }
        click(at: centerTK1(of: 7, in: textView), in: textView)
        XCTAssertTrue(clicked === attachment)
    }

    func testTK1PressReleasedOffTheImageFetchesNothing() {
        // A drag that starts on a placeholder (a selection, say) is not a request to load it.
        let attachment = RichTextImageAttachment(alt: "chart", url: remoteURL())
        let textView = makeTK1View(content([attachment]))
        let window = hostInWindow(textView)
        defer { window.close() }
        RichTextImageLoading.startLoading(in: textView.textStorage!, remoteImages: .onClick) {}
        var clicked: RichTextImageAttachment?
        textView.onHeldImageClick = { clicked = $0 }
        click(at: centerTK1(of: 7, in: textView), releasedAt: centerTK1(of: 1, in: textView), in: textView)
        XCTAssertNil(clicked)
        XCTAssertEqual(attachment.hold, .awaitingClick)
    }

    func testTK1PressWithModifiersIsLeftToTheTextView() {
        // Shift extends a selection and Control opens the menu; neither loads the image.
        let attachment = RichTextImageAttachment(alt: "chart", url: remoteURL())
        let textView = makeTK1View(content([attachment]))
        let window = hostInWindow(textView)
        defer { window.close() }
        RichTextImageLoading.startLoading(in: textView.textStorage!, remoteImages: .onClick) {}
        var clicked: RichTextImageAttachment?
        textView.onHeldImageClick = { clicked = $0 }
        let onImage = centerTK1(of: 7, in: textView)
        for modifiers in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let press = mouseEvent(.leftMouseDown, at: onImage, in: textView, modifiers: modifiers)
            XCTAssertFalse(textView.handleHeldImageClick(press), "\(modifiers)")
        }
        XCTAssertNil(clicked)
        XCTAssertEqual(attachment.hold, .awaitingClick)
    }

    func testTK2FindsTheHeldImageAndReachesTheHook() {
        let attachment = RichTextImageAttachment(alt: "chart", url: remoteURL())
        let (view, owner) = RichTextAppKit.makeTextKit2View(attributed: content([attachment]),
                                                           metrics: RichTextDecorationMetrics())
        withExtendedLifetime(owner) {
            guard let textView = view as? SelectableTextView else {
                return XCTFail("the TK2 factory makes a SelectableTextView")
            }
            textView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            let window = hostInWindow(textView)
            defer { window.close() }
            RichTextImageLoading.startLoading(in: textView.textStorage!, remoteImages: .onClick) {}
            textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
            // The view fits its height to the content on its first layout pass; let that happen before any
            // point is taken, as it has long before a user can click a view on screen.
            textView.sizeToFit()

            let screenRect = textView.firstRect(forCharacterRange: NSRange(location: 7, length: 1), actualRange: nil)
            let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            let onImage = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertGreaterThan(rect.width, 100, "sanity: the placeholder is laid out at its full width")
            XCTAssertTrue(RichTextImageLoading.heldAttachment(at: onImage, in: textView) === attachment)

            var clicked: RichTextImageAttachment?
            textView.onHeldImageClick = { clicked = $0 }
            click(at: onImage, in: textView)
            XCTAssertTrue(clicked === attachment)
        }
    }
    #endif
}

#if canImport(AppKit)
// Content that runs `beforeSecondPass` when its attachments are enumerated the second time - in startLoading,
// after its applyCached pass and before the pass that fetches - to hold the loading pass at that point.
private final class ImageArrivesMidPass: NSAttributedString {
    private let backing: NSAttributedString
    private let beforeSecondPass: () -> Void
    private var passes = 0

    init(_ backing: NSAttributedString, beforeSecondPass: @escaping () -> Void) {
        self.backing = backing
        self.beforeSecondPass = beforeSecondPass
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) has not been implemented")
    }

    override var string: String {
        return backing.string
    }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        return backing.attributes(at: location, effectiveRange: range)
    }

    override func enumerateAttribute(_ attrName: NSAttributedString.Key, in enumerationRange: NSRange,
                                     options opts: NSAttributedString.EnumerationOptions = [],
                                     using block: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        passes += 1
        if passes == 2 {
            beforeSecondPass()
        }
        super.enumerateAttribute(attrName, in: enumerationRange, options: opts, using: block)
    }
}
#endif
