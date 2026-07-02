// Generates Demo/Resources/TypographyTour.rtf by building the NSAttributedString programmatically
// (NSTextTable, NSTextList, and a tour of TextKit-renderable attributes) and serializing to RTF via
// AppKit's own writer - guaranteeing the Cocoa RTF importer round-trips every feature. Re-run after
// edits: swift generate_rtf.swift <output-path>
import AppKit

let doc = NSMutableAttributedString()

func plain(_ text: String, _ attrs: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
    var a = attrs
    if a[.font] == nil { a[.font] = NSFont.systemFont(ofSize: 13) }
    return NSAttributedString(string: text, attributes: a)
}

func para(_ text: String, _ attrs: [NSAttributedString.Key: Any] = [:]) {
    doc.append(plain(text + "\n", attrs))
}

func heading(_ text: String, size: CGFloat = 22) {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = 14
    style.paragraphSpacing = 6
    para(text, [.font: NSFont.boldSystemFont(ofSize: size), .paragraphStyle: style])
}

// --- Title ---
heading("Typography Tour (RTF)", size: 26)
para("Every feature below is carried by this one RTF file and rendered by RichText's TextKit engines. SwiftUI's Text view drops most of them.")

// --- Inline styles ---
heading("Inline styles")
let line = NSMutableAttributedString()
line.append(plain("bold", [.font: NSFont.boldSystemFont(ofSize: 13)]))
line.append(plain(", "))
line.append(plain("italic", [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)]))
line.append(plain(", "))
line.append(plain("underline", [.underlineStyle: NSUnderlineStyle.single.rawValue]))
line.append(plain(", "))
line.append(plain("double underline", [.underlineStyle: NSUnderlineStyle.double.rawValue]))
line.append(plain(", "))
line.append(plain("colored dashed underline", [.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue, .underlineColor: NSColor.systemRed]))
line.append(plain(", "))
line.append(plain("strikethrough", [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
line.append(plain(", "))
line.append(plain("red strikethrough", [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.systemRed]))
line.append(plain(", "))
line.append(plain("colored text", [.foregroundColor: NSColor.systemBlue]))
line.append(plain(", "))
line.append(plain("highlighted", [.backgroundColor: NSColor.systemYellow]))
line.append(plain(", "))
line.append(plain("outline", [.strokeWidth: 3.0]))
line.append(plain(", "))
line.append(plain("shadow", [.shadow: { let s = NSShadow(); s.shadowOffset = NSSize(width: 1.5, height: -1.5); s.shadowBlurRadius = 2; s.shadowColor = NSColor.gray; return s }()]))
line.append(plain(", "))
line.append(plain("expanded tracking", [.expansion: 0.35]))
line.append(plain(", "))
line.append(plain("tight kerning", [.kern: -1.2]))
line.append(plain(".\n"))
doc.append(line)

// Super / subscript.
let sup = NSMutableAttributedString()
sup.append(plain("Superscript: E = mc"))
sup.append(plain("2", [.font: NSFont.systemFont(ofSize: 9), .superscript: 1]))
sup.append(plain("; subscript: H"))
sup.append(plain("2", [.font: NSFont.systemFont(ofSize: 9), .superscript: -1]))
sup.append(plain("O. A "))
sup.append(plain("link to swift.org", [.link: URL(string: "https://swift.org")!]))
sup.append(plain(" is clickable.\n"))
doc.append(sup)

// Fonts.
let fonts = NSMutableAttributedString()
fonts.append(plain("Fonts: "))
fonts.append(plain("Helvetica ", [.font: NSFont(name: "Helvetica", size: 13)!]))
fonts.append(plain("Times ", [.font: NSFont(name: "Times-Roman", size: 14)!]))
fonts.append(plain("Courier ", [.font: NSFont(name: "Courier", size: 13)!]))
fonts.append(plain("Zapfino", [.font: NSFont(name: "Zapfino", size: 11)!]))
fonts.append(plain(".\n"))
doc.append(fonts)

// --- Paragraph styles ---
heading("Paragraph styles")
func aligned(_ text: String, _ alignment: NSTextAlignment) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    para(text, [.paragraphStyle: style])
}
aligned("Left aligned: the default, nothing special to see here.", .left)
aligned("Center aligned: this paragraph sits in the middle.", .center)
aligned("Right aligned: this paragraph hugs the right edge.", .right)
aligned("Justified: this paragraph stretches its lines to both margins, which needs enough text to wrap onto at least a couple of lines so the effect is visible.", .justified)

let indent = NSMutableParagraphStyle()
indent.firstLineHeadIndent = 28
indent.headIndent = 0
para("First-line indent: the classic book-paragraph opening, where only the first line steps in and the rest of the paragraph returns to the margin as it wraps.", [.paragraphStyle: indent])

let hanging = NSMutableParagraphStyle()
hanging.firstLineHeadIndent = 0
hanging.headIndent = 28
para("Hanging indent: the first line starts at the margin and every following wrapped line is pushed in, the shape used by definitions and bibliographies.", [.paragraphStyle: hanging])

let spaced = NSMutableParagraphStyle()
spaced.lineHeightMultiple = 1.8
para("Line spacing: this paragraph uses 1.8x line height, so its wrapped lines float far apart compared to the rest of the document. It needs to wrap to show, so here is some filler to make sure it does.", [.paragraphStyle: spaced])

// --- Lists (NSTextList) ---
heading("Lists")
func list(_ items: [String], format: NSTextList.MarkerFormat, ordered: Bool) {
    let textList = NSTextList(markerFormat: format, options: 0)
    for (i, item) in items.enumerated() {
        let style = NSMutableParagraphStyle()
        style.textLists = [textList]
        style.headIndent = 36
        style.firstLineHeadIndent = 12
        style.tabStops = [NSTextTab(textAlignment: .left, location: 36)]
        // No leading tab: Cocoa's RTF writer folds a "\t<marker>\t" prefix into \listtext, which the
        // importer then CONSUMES - the marker would vanish for read-only display. "<marker>\t" keeps the
        // marker as real text AND keeps the NSTextList in the paragraph style.
        let marker = ordered ? "\(i + 1).\t" : "\u{2022}\t"
        para(marker + item, [.paragraphStyle: style])
    }
}
list(["A bulleted item", "Another bulleted item", "NSTextList carries the list structure"], format: .disc, ordered: false)
list(["First ordered item", "Second ordered item"], format: .decimal, ordered: true)

// --- Table (NSTextTable) ---
heading("Table")
para("A real NSTextTable with borders and a shaded header row - TextKit 1 on macOS lays this out natively:")

let table = NSTextTable()
table.numberOfColumns = 3
func cell(_ text: String, row: Int, col: Int, header: Bool) -> NSAttributedString {
    let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
    block.setBorderColor(NSColor.gray)
    block.setWidth(1, type: .absoluteValueType, for: .border)
    block.setWidth(5, type: .absoluteValueType, for: .padding)
    if header { block.backgroundColor = NSColor.lightGray }
    let style = NSMutableParagraphStyle()
    style.textBlocks = [block]
    let font = header ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
    return NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: style])
}
let rows: [[String]] = [
    ["Feature", "TextKit", "SwiftUI Text"],
    ["Tables", "native (TK1 macOS)", "dropped"],
    ["Attachments", "rendered", "dropped"],
    ["Paragraph styles", "full", "ignored"],
]
for (r, cols) in rows.enumerated() {
    for (c, text) in cols.enumerated() {
        doc.append(cell(text, row: r, col: c, header: r == 0))
    }
}

para("Text after the table confirms normal flow resumes.")

// --- Serialize ---
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TypographyTour.rtf"
let data = try doc.data(from: NSRange(location: 0, length: doc.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
try data.write(to: URL(fileURLWithPath: out))

// --- Verify round-trip ---
let reread = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
var foundTable = false, foundList = false, foundShadow = false, foundKern = false
var foundDoubleUnderline = false, foundSuper = false, foundBG = false, foundStroke = false
reread.enumerateAttributes(in: NSRange(location: 0, length: reread.length)) { attrs, _, _ in
    if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
        if !ps.textBlocks.isEmpty { foundTable = true }
        if !ps.textLists.isEmpty { foundList = true }
    }
    if attrs[.shadow] != nil { foundShadow = true }
    if let k = attrs[.kern] as? NSNumber, k.doubleValue != 0 { foundKern = true }
    if let u = attrs[.underlineStyle] as? NSNumber, u.intValue & NSUnderlineStyle.double.rawValue == NSUnderlineStyle.double.rawValue { foundDoubleUnderline = true }
    if let s = attrs[.superscript] as? NSNumber, s.intValue != 0 { foundSuper = true }
    if attrs[.backgroundColor] != nil { foundBG = true }
    if let w = attrs[.strokeWidth] as? NSNumber, w.doubleValue > 0 { foundStroke = true }
}
print("round-trip: table=\(foundTable) list=\(foundList) shadow=\(foundShadow) kern=\(foundKern) doubleUnderline=\(foundDoubleUnderline) superscript=\(foundSuper) background=\(foundBG) stroke=\(foundStroke)")
print("wrote \(out) (\(data.count) bytes)")
