// Makes the test PDFs that phone checks hand the owner (#1038). Run from the repo root:
//   swift TestPlans/phone-files/make-test-pdfs.swift TestPlans/phone-files
// outline-chapters-test.pdf (#347): four chapters that exist only as bookmarks; no page prints a heading.
// footer-stamp-test.pdf (#162): "Downloaded on 25 September 2026" with the page number on the same line,
// which PDFKit reads as one line ("Downloaded on 25 September 2026 1").
import Foundation
import CoreGraphics
import CoreText
import PDFKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(_ ctx: CGContext, _ s: String, _ size: CGFloat, _ rect: CGRect, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let fs = CTFramesetterCreateWithAttributedString(attr)
    CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
}

// #347: chapters exist only as bookmarks. No chapter heading is printed on any page.
let chapters: [(String, String)] = [
    ("The Lighthouse Keeper", "Every evening at dusk the keeper climbed the ninety steps and lit the lamp. He had done it for eleven years, and in all that time no ship had come close enough to need it. He kept a ledger anyway, writing the weather and the hour in a small, careful hand. On the night this story begins, the ledger said only: wind from the north, sea calm, a light seen far out where no light should be. He watched it for an hour before it went out, and then he sat with the pencil in his hand and did not write anything at all."),
    ("Salt and Iron", "The supply boat came on the first of each month, carrying flour, lamp oil and letters. This month it carried a passenger, a surveyor named Ada with a case of brass instruments and a habit of asking questions that had no easy answers. She wanted to know why the lamp was lit when the shipping lane had moved twenty miles south. The keeper said it was his job. She said that was not the same thing as a reason, and wrote something in her own ledger, which was much larger than his."),
    ("The Long Winter", "Ice closed the harbour in December and the supply boat stopped coming. Ada stayed, because there was no way to leave, and the two of them settled into a routine of measurements and arguments. She measured the tides and the stars. He measured the oil, which was running low. By February they had stopped arguing about whether the lamp mattered and started arguing about how long it could last. The light far out at sea came back twice that winter, and both times they watched it together without saying a word."),
    ("Homecoming", "When the ice broke in April, the supply boat returned with a new keeper and a letter closing the station. The lamp would be dark by summer. Ada packed her instruments and offered him a place on the boat. He climbed the ninety steps one more time, lit the lamp, and wrote in the ledger: wind from the south, sea calm, no light seen. Then he closed the book, left it on the table for whoever came next, and went down to the water."),
]
let bookURL = outDir.appending(path: "outline-chapters-test.pdf")
do {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(bookURL as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    draw(ctx, "The Last Lamp", 28, CGRect(x: 72, y: 600, width: 468, height: 50), bold: true)
    draw(ctx, "A short test book for Spoken Margins. Its four chapters are bookmarks only: no page prints a chapter heading. The app's chapter list should show the four bookmark names.", 12, CGRect(x: 72, y: 460, width: 468, height: 120))
    ctx.endPDFPage()
    for (_, body) in chapters {
        ctx.beginPDFPage(nil)
        draw(ctx, body, 12, CGRect(x: 72, y: 200, width: 468, height: 520))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}
let doc = PDFDocument(url: bookURL)!
let root = PDFOutline()
for (i, (title, _)) in chapters.enumerated() {
    let item = PDFOutline()
    item.label = title
    item.destination = PDFDestination(page: doc.page(at: i + 1)!, at: CGPoint(x: 72, y: 740))
    root.insertChild(item, at: root.numberOfChildren)
}
doc.outlineRoot = root
precondition(doc.write(to: bookURL))

// #162: "Downloaded on ..." footer with the page number on the same baseline.
let stampPages: [(String, String)] = [
    ("Footer Test, Part One", "This page checks the small print at the bottom of each page. At the foot of this page there is a line that says when the file was downloaded, followed by a page number on the same line. Neither should be read aloud. If you hear a date in September or a bare number when this page ends, the check has failed. The rest of this paragraph is ordinary prose, here only so the page sounds like a page. A good listening edition keeps what the author wrote and drops the scaffolding around it."),
    ("Footer Test, Part Two", "The second page repeats the same footer with a different page number. Listen to the moment this paragraph ends and the next page begins. You should go straight from the last sentence here to the heading of part three, with nothing in between: no download date, no page number, no running title."),
    ("Footer Test, Part Three", "This is the last page. When it finishes, the item should simply end. If the whole file played without any mention of downloads or page numbers, the check passes."),
]
let stampURL = outDir.appending(path: "footer-stamp-test.pdf")
do {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(stampURL as CFURL, mediaBox: &box, nil)!
    for (i, p) in stampPages.enumerated() {
        ctx.beginPDFPage(nil)
        draw(ctx, p.0, 18, CGRect(x: 72, y: 690, width: 468, height: 40), bold: true)
        draw(ctx, p.1, 12, CGRect(x: 72, y: 200, width: 468, height: 480))
        draw(ctx, "Downloaded on 25 September 2026", 9, CGRect(x: 72, y: 40, width: 300, height: 14))
        draw(ctx, "\(i + 1)", 9, CGRect(x: 530, y: 40, width: 20, height: 14))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}
print("ok")
