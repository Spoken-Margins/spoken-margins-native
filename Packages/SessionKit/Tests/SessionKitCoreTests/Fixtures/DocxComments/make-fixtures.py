#!/usr/bin/env python3
"""Makes the Word documents and the manifest that DocxCommentWriterTests reads (#4595). Run from anywhere:

    python3 Packages/SessionKit/Tests/SessionKitCoreTests/Fixtures/DocxComments/make-fixtures.py

It writes beside itself one .docx per row of the issue's table (the CASES list below) and cases.json, which says for
each Margin the sentence as the item's text spells it, the text before it, the comment, and what the comment must
cover in the copy. With `--check FILE.docx` it instead opens a writer's output with the Mac's `textutil` and with
Python's own XML parser, the readers the PR names, and prints the comments it finds.

The text is public domain (Jane Austen, "Pride and Prejudice", 1813; Herman Melville, "Moby-Dick", 1851; Mary Shelley,
"Frankenstein", 1818). The packages are written by hand with fixed timestamps, so the bytes are the same on every run
and a reviewer can read every part.
"""
import json
import pathlib
import subprocess
import sys
import zipfile
import xml.dom.minidom

HERE = pathlib.Path(__file__).resolve().parent
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
STAMP = (2026, 11, 18, 12, 0, 0)


def run(text, props=""):
    rpr = f"<w:rPr>{props}</w:rPr>" if props else ""
    return f'<w:r w:rsidR="00A1B2C3">{rpr}<w:t xml:space="preserve">{text}</w:t></w:r>'


def para(*content, ppr=""):
    pp = f"<w:pPr>{ppr}</w:pPr>" if ppr else ""
    return f'<w:p w:rsidR="00A1B2C3">{pp}{"".join(content)}</w:p>'


def document(body):
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        f'<w:document xmlns:w="{W}" xmlns:r="{R}"><w:body>{body}'
        '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>'
    )


def package(name, body, extra_parts=None, extra_rels="", extra_types=""):
    parts = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            f"{extra_types}</Types>"
        ),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'officeDocument" Target="word/document.xml"/></Relationships>'
        ),
        "word/document.xml": document(body),
        "word/_rels/document.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f"{extra_rels}</Relationships>"
        ),
    }
    parts.update(extra_parts or {})
    for part, text in parts.items():
        xml.dom.minidom.parseString(text.encode())  # every part is well-formed before it is written
    with zipfile.ZipFile(HERE / name, "w", zipfile.ZIP_DEFLATED) as archive:
        for part, text in parts.items():
            info = zipfile.ZipInfo(part, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, text.encode())


AUSTEN_1 = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."
AUSTEN_2 = "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters."
AUSTEN_3 = "Mr. Bennet replied that he had not."
MOBY_1 = "Call me Ishmael."
MOBY_2 = "Some years ago, never mind how long precisely, having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world."
MOBY_3 = "It is a way I have of driving off the spleen and regulating the circulation."
SHELLEY_1 = "You will rejoice to hear that no disaster has accompanied the commencement of an enterprise which you have regarded with such evil forebodings."
SHELLEY_2 = "I arrived here yesterday, and my first task is to assure my dear sister of my welfare."

CASES = []


def case(name, file, margins, note):
    CASES.append({"name": name, "file": file, "note": note, "margins": margins})


def margin(mid, sentence, expected, preceding="", comment=None, spot="sentence", paragraph=None):
    return {
        "marginId": mid,
        "sentenceText": sentence,
        "precedingText": preceding,
        "commentText": comment or f"Comment {mid}: worth a second look.",
        "expectedCommentedText": expected,
        "expectedSpot": spot,
        "expectedParagraphContains": paragraph,
    }


# 1. Inside one run: three sentences in a single w:t. Two Margins split it in the middle, one ends at its end, and a
#    third Margin shares the middle sentence.
package("one-run.docx", para(run(f"{AUSTEN_1} {AUSTEN_2} {AUSTEN_3}")))
case("sentence inside one run", "one-run.docx", [
    margin("m1", AUSTEN_2, AUSTEN_2, preceding=AUSTEN_1 + " "),
    margin("m2", AUSTEN_3, AUSTEN_3, preceding=AUSTEN_2[-80:] + " "),
    margin("m3", AUSTEN_2, AUSTEN_2, preceding=AUSTEN_1 + " ", comment="A second Margin on the same sentence."),
], "splits one w:t twice; one comment ends at the run's end")

# 2. Across runs with different formatting; the sentence ends mid-run.
package("formatted-runs.docx", para(
    run("It is a truth "),
    run("universally acknowledged", "<w:b/>"),
    run(", that a single man in possession of a good fortune, "),
    run("must be in want of a wife. However little known", "<w:i/>"),
    run(AUSTEN_2[len("However little known"):]),
))
case("across runs with different formatting", "formatted-runs.docx", [
    margin("m1", AUSTEN_1, AUSTEN_1),
], "starts at a run's edge, ends inside an italic run")

# 3. Across a hyperlink.
package(
    "hyperlink.docx",
    para(
        run(f"{MOBY_1} Some years ago, never mind how long precisely, having "),
        '<w:hyperlink r:id="rIdLink1" w:history="1">'
        + run("little or no money", '<w:rStyle w:val="Hyperlink"/><w:u w:val="single"/>')
        + "</w:hyperlink>",
        run(f" in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. {MOBY_3}"),
    ),
    extra_rels='<Relationship Id="rIdLink1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'hyperlink" Target="https://www.gutenberg.org/ebooks/2701" TargetMode="External"/>',
)
case("across a hyperlink", "hyperlink.docx", [
    margin("m1", MOBY_2, MOBY_2, preceding=MOBY_1 + " "),
], "the sentence runs through a w:hyperlink")

# 4. Inside a table cell.
cell = lambda content: f'<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr>{content}</w:tc>'
package("table-cell.docx", para(run("Letters from the north.")) + (
    '<w:tbl><w:tblPr><w:tblW w:w="8000" w:type="dxa"/></w:tblPr>'
    '<w:tblGrid><w:gridCol w:w="4000"/><w:gridCol w:w="4000"/></w:tblGrid>'
    f'<w:tr>{cell(para(run("Letter 1")))}{cell(para(run(f"{SHELLEY_1} {SHELLEY_2}")))}</w:tr></w:tbl>'
) + para(run("The end of the letter.")))
case("inside a table cell", "table-cell.docx", [
    margin("m1", SHELLEY_2, SHELLEY_2, preceding=SHELLEY_1[-80:] + " "),
], "the sentence is the second in a w:tc paragraph")

# 5. In a list item.
numbering = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    f'<w:numbering xmlns:w="{W}"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/>'
    '<w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>'
)
item = lambda text: para(run(text), ppr='<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>')
package(
    "list-item.docx",
    para(run("Three opening lines:")) + item(MOBY_1) + item(f"{AUSTEN_1} {AUSTEN_3}") + item(SHELLEY_2),
    extra_parts={"word/numbering.xml": numbering},
    extra_rels='<Relationship Id="rIdNum1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'numbering" Target="numbering.xml"/>',
    extra_types='<Override PartName="/word/numbering.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>',
)
case("in a list item", "list-item.docx", [
    margin("m1", AUSTEN_1, AUSTEN_1, preceding="Three opening lines:\n\nCall me Ishmael.\n\n"),
], "the sentence is in a numbered paragraph after its w:numPr")

# 6. The same sentence twice; the Margin's preceding text picks the second.
REPEAT = "Nothing more was heard of it that night."
package("same-sentence-twice.docx",
        para(run(f"The first bell rang at noon. {REPEAT}")) + para(run(f"The second bell rang at dusk. {REPEAT}")))
case("the same sentence twice", "same-sentence-twice.docx", [
    margin("m1", REPEAT, REPEAT, preceding="The first bell rang at noon. " + REPEAT + "\n\nThe second bell rang at dusk. ",
           paragraph="second bell"),
    margin("m2", REPEAT, REPEAT, preceding="The first bell rang at noon. ", paragraph="first bell"),
], "two identical sentences in two paragraphs")

# 7. Tracked changes around and inside the sentence: an insertion inside it, a deletion inside it, and a deleted
#    sentence just before it. The item's text holds what the document shows (w:t), not deleted text (w:delText).
package("tracked-changes.docx", para(
    '<w:del w:id="101" w:author="Editor" w:date="2026-01-01T00:00:00Z"><w:r><w:delText xml:space="preserve">'
    "She was not to be trusted. </w:delText></w:r></w:del>",
    run("Elizabeth was "),
    '<w:ins w:id="102" w:author="Editor" w:date="2026-01-01T00:00:00Z">' + run("very ") + "</w:ins>",
    '<w:del w:id="103" w:author="Editor" w:date="2026-01-01T00:00:00Z"><w:r><w:delText xml:space="preserve">'
    "rather </w:delText></w:r></w:del>",
    run("fond of walking. Her sister preferred the carriage."),
))
case("tracked changes around the sentence", "tracked-changes.docx", [
    margin("m1", "Elizabeth was very fond of walking.", "Elizabeth was very fond of walking."),
], "w:ins inside the sentence and w:del before and inside it")

# 8. A document that already has a comment (id 0 on the first sentence): the new one is appended with a new id.
existing_comments = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    f'<w:comments xmlns:w="{W}"><w:comment w:id="0" w:author="Professor" w:date="2026-01-01T00:00:00Z" w:initials="P">'
    '<w:p><w:r><w:annotationRef/></w:r><w:r><w:t>Strong opening.</w:t></w:r></w:p></w:comment></w:comments>'
)
package(
    "existing-comments.docx",
    para('<w:commentRangeStart w:id="0"/>', run(MOBY_1), '<w:commentRangeEnd w:id="0"/>',
         '<w:r><w:commentReference w:id="0"/></w:r>', run(f" {MOBY_3}")),
    extra_parts={"word/comments.xml": existing_comments},
    extra_rels='<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'comments" Target="comments.xml"/>',
    extra_types='<Override PartName="/word/comments.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>',
)
case("a document that already has comments", "existing-comments.docx", [
    margin("m1", MOBY_3, MOBY_3, preceding=MOBY_1 + " "),
], "keeps comment 0 and its range; the new comment gets id 1")

# 9. Smart quotes and Unicode: the document has curly quotes, an em dash and a composed é; the item's text has
#    straight quotes and a decomposed é.
package("smart-quotes.docx", para(run(
    "“I am perfectly convinced by it that Mr. Darcy has no defect,” said the café owner — "
    "and nobody disagreed. The tea was cold."
)))
case("smart quotes and Unicode", "smart-quotes.docx", [
    margin("m1", "\"I am perfectly convinced by it that Mr. Darcy has no defect,\" said the café owner — and nobody disagreed.",
           "“I am perfectly convinced by it that Mr. Darcy has no defect,” said the café owner — and nobody disagreed.",
           comment="Quote marks & accents: “defect” <checked>."),
], "curly versus straight quotes, NFC versus NFD")

# 10. A sentence not found: the paragraph that held it (found by the text before it), then the first paragraph.
package("not-found.docx",
        para(run(SHELLEY_1), ppr='<w:jc w:val="center"/>')
        + para(run(f"{SHELLEY_2} The weather here is cold."), ppr='<w:jc w:val="both"/>')
        + para(run(MOBY_3)))
case("a sentence not found", "not-found.docx", [
    margin("m1", "This sentence was cut from the draft before it was sent.",
           f"{SHELLEY_2} The weather here is cold.", preceding=SHELLEY_2 + " ", spot="paragraph"),
    margin("m2", "Nor was this one ever written down.", SHELLEY_1,
           preceding="Words from another book entirely, which this document never held.", spot="firstParagraph"),
], "paragraph fallback, then first-paragraph fallback; both paragraphs have a w:pPr the comment must follow")

(HERE / "cases.json").write_text(json.dumps({"cases": CASES}, indent=2, ensure_ascii=False) + "\n")


def check(path):
    """Opens a writer's output with textutil and Python's XML parser and prints what a reader sees."""
    text = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(path)], check=True, capture_output=True, text=True).stdout
    print(f"textutil: {len(text.split())} words")
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.endswith(".xml") or name.endswith(".rels"):
                xml.dom.minidom.parseString(archive.read(name))
        comments = xml.dom.minidom.parseString(archive.read("word/comments.xml"))
        for comment in comments.getElementsByTagName("w:comment"):
            words = "".join(t.firstChild.data for t in comment.getElementsByTagName("w:t") if t.firstChild)
            print(f"comment {comment.getAttribute('w:id')} by {comment.getAttribute('w:author')}: {words}")


if __name__ == "__main__" and len(sys.argv) > 2 and sys.argv[1] == "--check":
    for target in sys.argv[2:]:
        check(target)
