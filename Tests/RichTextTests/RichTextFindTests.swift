// Tests/RichTextTests/RichTextFindTests.swift
//
// Layers 2 and 3 of the find stack: highlights are draw-only (neither engine touches the text storage),
// stale ranges are clipped rather than asserted on, the current match has a frame, and the controller's
// cursor behaves (wraps, survives a re-bind, clears with the query).

import XCTest
import SwiftUI
@testable import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class RichTextFindTests: XCTestCase {

    private let markdown = "The quick brown fox jumps over the lazy dog. The fox again.\n\nA second paragraph about a fox."

    // MARK: - TextKit 1

    func testTextKit1HighlightsDoNotMutateStorageAndHaveFrames() {
        let attributed = RichTextAttributedString.make(RichTextDocument(markdown: markdown), engine: .textKit1)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = RichTextLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let matches = RichTextSearch.matches(in: attributed, query: "fox")
        XCTAssertEqual(matches.count, 3)
        let before = NSAttributedString(attributedString: storage)
        layoutManager.highlights = RichTextHighlights(matches: matches, current: 1)
        XCTAssertTrue(storage.isEqual(to: before), "highlights must be draw-only")

        let frame = layoutManager.frame(of: matches[1].range, in: container)
        XCTAssertNotNil(frame)
        XCTAssertGreaterThan(frame!.width, 0)
        XCTAssertGreaterThan(frame!.height, 0)
        // The third match is in the second paragraph: lower on the page than the first.
        let first = layoutManager.frame(of: matches[0].range, in: container)!
        let third = layoutManager.frame(of: matches[2].range, in: container)!
        XCTAssertGreaterThan(third.minY, first.minY)

        // A range past the end (stale query after the document shrank) is clipped, not fatal.
        XCTAssertNil(layoutManager.frame(of: NSRange(location: 10_000, length: 3), in: container))
        layoutManager.highlights = RichTextHighlights(ranges: [NSRange(location: 10_000, length: 3)])
        XCTAssertEqual(layoutManager.highlights?.clipped(to: storage.length).count, 0)
    }

    // MARK: - TextKit 2

    func testTextKit2HighlightsAreRenderingAttributesOnly() {
        let document = RichTextDocument(markdown: markdown)
        #if canImport(AppKit)
        let (textView, owner) = RichTextAppKit.makeTextKit2View(document)
        #else
        let (textView, owner) = RichTextUIKit.makeTextKit2View(document)
        #endif
        withExtendedLifetime(owner) {
            textView.frame = CGRect(x: 0, y: 0, width: 300, height: 1000)
            guard let layoutManager = textView.textLayoutManager, let storage = textView.textStorage else {
                return XCTFail("no TextKit 2 stack")
            }
            let matches = RichTextSearch.matches(in: storage, query: "fox")
            XCTAssertEqual(matches.count, 3)
            let before = NSAttributedString(attributedString: storage)
            RichTextHighlightTK2.apply(RichTextHighlights(matches: matches, current: 0), to: layoutManager)
            XCTAssertTrue(storage.isEqual(to: before), "rendering attributes must not reach the storage")

            // The rendering attribute is there for the match and absent just before it.
            let contentManager = layoutManager.textContentManager!
            let start = contentManager.location(layoutManager.documentRange.location, offsetBy: matches[0].range.location)!
            XCTAssertNotNil(renderingBackground(at: start, in: layoutManager))
            let outside = layoutManager.documentRange.location
            XCTAssertNil(renderingBackground(at: outside, in: layoutManager))

            XCTAssertNotNil(RichTextHighlightTK2.frame(of: matches[2].range, in: layoutManager))
            XCTAssertNil(RichTextHighlightTK2.frame(of: NSRange(location: 10_000, length: 3), in: layoutManager))

            RichTextHighlightTK2.apply(nil, to: layoutManager)
            XCTAssertNil(renderingBackground(at: start, in: layoutManager))
        }
    }

    // The rendering attributes in force at `location` (the first block the enumeration yields from there).
    private func renderingBackground(at location: any NSTextLocation, in layoutManager: NSTextLayoutManager) -> Any? {
        var found: Any?
        layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, range in
            if range.contains(location) {
                found = attributes[.backgroundColor]
            }
            return false
        }
        return found
    }

    // MARK: - Highlights value

    func testEmptyHighlightsClearAndCurrentRangeResolves() {
        let view = RichText(markdown: "abc").findHighlights(RichTextHighlights(ranges: []))
        XCTAssertNotNil(view)   // compiles and clears; the representable sees nil
        let highlights = RichTextHighlights(ranges: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)], current: 1)
        XCTAssertEqual(highlights.currentRange, NSRange(location: 2, length: 1))
        XCTAssertNil(RichTextHighlights(ranges: [NSRange(location: 0, length: 1)], current: 5).currentRange)
    }

    // MARK: - Controller

    func testControllerCursorWrapsAndSummaryReads() {
        let controller = RichTextFindController()
        controller.bind(document: RichTextDocument(markdown: markdown))
        XCTAssertEqual(controller.summary, "")
        controller.query = "fox"
        XCTAssertEqual(controller.ranges.count, 3)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.summary, "1 of 3")
        controller.next()
        controller.next()
        XCTAssertEqual(controller.currentIndex, 2)
        controller.next()
        XCTAssertEqual(controller.currentIndex, 0, "wraps forward")
        controller.previous()
        XCTAssertEqual(controller.currentIndex, 2, "wraps backward")
        XCTAssertEqual(controller.highlights?.current, 2)

        controller.query = "zebra"
        XCTAssertEqual(controller.summary, "No matches")
        XCTAssertNil(controller.currentIndex)
        XCTAssertNil(controller.highlights)

        controller.query = ""
        XCTAssertEqual(controller.summary, "")
    }

    func testControllerKeepsCurrentMatchAcrossRebindAndOptionsChange() {
        let controller = RichTextFindController()
        controller.bind(text: "fox one fox two Fox three")
        controller.query = "fox"
        controller.next()
        XCTAssertEqual(controller.currentIndex, 1)
        // Same text re-bound (a view re-appeared): nothing moves.
        controller.bind(text: "fox one fox two Fox three")
        XCTAssertEqual(controller.currentIndex, 1)
        // Text grew in front: the old range no longer matches, cursor goes to the first hit.
        controller.bind(text: "intro fox one fox two Fox three")
        XCTAssertEqual(controller.currentIndex, 0)
        // Case sensitivity drops the capitalized one.
        controller.options.caseSensitive = true
        XCTAssertEqual(controller.ranges.count, 2)
        // A limit caps the count and the summary says so.
        controller.options = RichTextSearchOptions(limit: 1)
        XCTAssertEqual(controller.ranges.count, 1)
        XCTAssertEqual(controller.summary, "1 of 1+")
    }

    func testControllerReportsAnInvalidExpression() {
        let controller = RichTextFindController()
        controller.bind(text: "fox (fox) fox")
        controller.options.regularExpression = true
        controller.query = "(fox"
        XCTAssertEqual(controller.summary, "Invalid expression")
        XCTAssertTrue(controller.ranges.isEmpty)
        controller.query = "\\(fox\\)"
        XCTAssertEqual(controller.summary, "1 of 1")
        XCTAssertEqual(controller.ranges, [NSRange(location: 4, length: 5)])
        // Back to literal: the same characters are a fine query that the text does not contain.
        controller.options.regularExpression = false
        XCTAssertEqual(controller.summary, "No matches")
    }

    func testPresentBumpsFocusRequestsEveryTimeUnlessAHostAsksNotTo() {
        let controller = RichTextFindController()
        controller.present()
        controller.present()
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.focusRequests, 2)
        controller.markFocusHonored()
        XCTAssertEqual(controller.focusHonored, 2)
        controller.present(focus: false)
        XCTAssertEqual(controller.focusRequests, 2, "a host's present leaves focus alone")
    }

    func testDismissHidesAndClears() {
        let controller = RichTextFindController()
        controller.bind(text: "fox")
        controller.present()
        controller.query = "fox"
        XCTAssertTrue(controller.isPresented)
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(controller.ranges.isEmpty)
    }
}
