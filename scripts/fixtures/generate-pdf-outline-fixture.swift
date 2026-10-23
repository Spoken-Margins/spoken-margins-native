import AppKit
import PDFKit

// Writes App/TestFixtures/pdf-outline-collected-stories.pdf for
// Gate1AppModelWorkflowTests.testPDFOutlineDestinationsBypassContentsEntriesAndPreserveMoreThanTwelveChapters.
//
//   swift scripts/fixtures/generate-pdf-outline-fixture.swift App/TestFixtures/pdf-outline-collected-stories.pdf
//
// The test used to draw this PDF itself with UIFont.systemFont. On the iOS 27 simulator that font resolves
// to TimesNewRoman and the drawn file came back with no chapters, while the same file made here imported
// all 21 on the owner's iOS 27 iPhone (#2365). So it is built once on macOS, with Helvetica and PDFKit.
// Page 1 is a title and a printed contents list; pages 2-21 each open with one story's heading. The outline
// has 20 entries, "Story 1" to "Story 20", each pointing at the top of its story's page.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let titles = (1...20).map { "Story \($0)" }
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
// Fixed metadata so a rerun writes the same title and creator.
let info = [kCGPDFContextTitle: "Collected Stories", kCGPDFContextCreator: "generate-pdf-outline-fixture.swift"] as CFDictionary
let context = CGContext(out as CFURL, mediaBox: &box, info)!

func bold(_ size: CGFloat) -> NSFont { NSFont(name: "Helvetica-Bold", size: size)! }
func regular(_ size: CGFloat) -> NSFont { NSFont(name: "Helvetica", size: size)! }

func page(_ body: () -> Void) {
    context.beginPDFPage(nil)
    // Top-left origin, matching the UIKit coordinates the test used.
    context.translateBy(x: 0, y: 792)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
}

func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont) {
    (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font])
}

page {
    draw("Collected Stories", 40, 35, bold(26))
    draw("Edited by Example Author", 40, 78, regular(12))
    draw("Contents", 40, 110, bold(18))
    for (index, title) in titles.enumerated() {
        draw(title, 55, 145 + CGFloat(index * 23), bold(12))
    }
}
for title in titles {
    page {
        draw(title, 40, 40, bold(20))
        draw("This is the readable body of \(title), with enough ordinary prose to establish the document body font size.", 40, 85, regular(12))
    }
}
context.closePDF()

let document = PDFDocument(url: out)!
let root = PDFOutline()
for (index, title) in titles.enumerated() {
    let child = PDFOutline()
    child.label = title
    child.destination = PDFDestination(page: document.page(at: index + 1)!, at: CGPoint(x: 40, y: 740))
    root.insertChild(child, at: root.numberOfChildren)
}
document.outlineRoot = root
precondition(document.write(to: out), "could not write \(out.path)")

let check = PDFDocument(url: out)!
precondition(check.pageCount == 21, "expected 21 pages, got \(check.pageCount)")
precondition(check.outlineRoot?.numberOfChildren == 20, "expected 20 outline entries")
precondition(check.page(at: 1)?.string?.contains("Story 1") == true, "page 2 text is not extractable")
print("wrote \(out.path): \(check.pageCount) pages, \(check.outlineRoot!.numberOfChildren) outline entries")
