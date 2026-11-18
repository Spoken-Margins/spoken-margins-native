#!/usr/bin/env python3
"""Makes the PDFs and the manifest that PDFMarginPlacerTests reads (#4338). Run from anywhere:

    python3 Packages/SessionKit/Tests/SessionKitTests/Fixtures/PDFPlacement/make-fixtures.py

It writes beside itself:
  margin-placement.pdf   eight pages, one placement case each (the page list below)
  margin-placement.json  what each page draws (every line, where) and the document text the app would hold for it
  locked.pdf             one page behind a password, which a PDF reader refuses to add comments to

The text is public domain (Jane Austen, "Pride and Prejudice", 1813; the sentences marked "plain" are ours). The PDFs are
written by hand, with Helvetica and no embedded fonts, so the bytes are the same on every run and a reviewer can read them.
The test's fixture check fails first, and says so, when PDFKit reads a page differently from how it is drawn here.

Needs pypdf and cryptography, only for locked.pdf.
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
LEFT = 72
TOP = 720
LEADING = 16
SIZE = 12


def escape(text):
    assert not any(c in text for c in "()\\") and text.isascii(), text
    return text


class Page:
    def __init__(self, kind, rotation=0, continues=False):
        self.kind = kind
        self.rotation = rotation
        self.continues = continues  # the first paragraph carries on from the page before
        self.lines = []  # {"text", "x", "y", "joinsNext"}
        self.paragraphs = []  # each a list of indexes into lines
        self.ops = []

    def paragraph(self, lines, start_y=TOP, columns=None, gap=0):
        """Draws `lines` one under the other from `start_y`. `columns` is [(x, count), ...] for text that runs down one
        column and on at the top of the next. A line ending in '-' marks a word split across the line break."""
        columns = columns or [(LEFT, len(lines))]
        indexes, cursor = [], 0
        for x, count in columns:
            for row in range(count):
                text = lines[cursor]
                y = start_y - row * LEADING - gap
                self.lines.append({"text": text, "x": x, "y": y, "joinsNext": text.endswith("-")})
                indexes.append(len(self.lines) - 1)
                cursor += 1
        assert cursor == len(lines)
        self.paragraphs.append(indexes)

    def content(self):
        ops = []
        if self.kind == "scan":
            # A picture of a page, not text: pale paper and dark bars where the words would be.
            ops.append("0.93 g 72 100 468 600 re f")
            ops.append("0.25 g")
            for row in range(10):
                ops.append("90 %d %d 6 re f" % (660 - row * 22, 420 - (row % 3) * 40))
            return "\n".join(ops)
        for line in self.lines:
            matrix = "0 1 -1 0 %d %d" % (line["x"], line["y"]) if self.rotation == 90 else "1 0 0 1 %d %d" % (line["x"], line["y"])
            ops.append("BT /F1 %d Tf %s Tm (%s) Tj ET" % (SIZE, matrix, escape(line["text"])))
        return "\n".join(ops)

    def paragraph_text(self, indexes):
        out = ""
        for position, index in enumerate(indexes):
            line = self.lines[index]
            text = line["text"]
            if line["joinsNext"]:
                out += text[:-1]  # "inter-" + "ference" is one word
            else:
                out += text + (" " if position < len(indexes) - 1 else "")
        return out


pages = []

# Page 0: a paragraph whose sentences start and end in the middle of lines.
p = Page("text")
p.paragraph([
    "It is a truth universally acknowledged, that a single man in possession of",
    "a good fortune, must be in want of a wife. However little known the feelings",
    "or views of such a man may be on his first entering a neighbourhood, this",
    "truth is so well fixed in the minds of the surrounding families, that he is",
    "considered the rightful property of some one or other of their daughters.",
    "Mr. Bennet replied that he had not.",
])
pages.append(p)

# Page 1: a word split across a line end with a hyphen.
p = Page("text")
p.paragraph([
    "We repeated the measurement three times to be sure. The inter-",
    "ference between the two waves was the surprise of the whole experiment.",
])
pages.append(p)

# Page 2: two columns. The first sentence is wholly in the left column; the second starts in the left column and ends in
# the right one; the paragraph reads down the left column and on at the top of the right (the order of the page's drawing).
p = Page("text")
p.paragraph([
    "The committee met on a cold Tuesday.",
    "It voted to build the new bridge at",
    "the narrow crossing. Nobody spoke",
    "against it, because the old ford had",
    "drowned two carters that spring and",
    "a good dog. The bridge opened in June.",
    "Children ran across it before the",
    "paint was dry.",
], columns=[(LEFT, 5), (330, 3)])
pages.append(p)

# Pages 3 and 4: one sentence that starts at the foot of a page and ends on the next.
p = Page("text")
p.paragraph([
    "The harvest was early that year. The river had risen higher than anyone",
    "remembered, and by the time the last cart crossed the ford the water",
], start_y=170)
pages.append(p)
p = Page("text", continues=True)
p.paragraph([
    "was already at the axles of the oxen. Nobody went back for the rest.",
])
pages.append(p)

# Page 5: the same sentence twice on one page, after different words.
p = Page("text")
p.paragraph(["The first day ended without an answer. We went home."])
p.paragraph(["The second day ended the same way. We went home."], start_y=TOP - 2 * LEADING)
pages.append(p)

# Page 6: a page stored upright and turned a quarter turn with /Rotate, so its text reads sideways in the file.
p = Page("text", rotation=90)
p.paragraph([
    "The old lighthouse stood at the edge of the cliff for two hundred years.",
    "Its keeper never once left it.",
], start_y=100)
pages.append(p)

# Page 7: a scan. Nothing on it can be read as text.
pages.append(Page("scan"))


def lay_out_rotated(page):
    """Stored x grows by one line height per line; the stored y is where each line starts."""
    for number, line in enumerate(page.lines):
        line["x"] = 110 + number * LEADING
        line["y"] = 100


lay_out_rotated(pages[6])


def write_pdf(path, page_list):
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    tree = add(None)
    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    kids = []
    for page in page_list:
        stream = page.content().encode("ascii")
        contents = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        rotate = b" /Rotate %d" % page.rotation if page.rotation else b""
        page_object = add(
            b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792]%s /Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
            % (tree, rotate, font, contents)
        )
        kids.append(page_object)
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % tree
    objects[tree - 1] = b"<< /Type /Pages /Count %d /Kids [%s] >>" % (len(kids), b" ".join(b"%d 0 R" % k for k in kids))
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref)
    path.write_bytes(bytes(out))


def manifest(page_list):
    document_text = ""
    page_starts = []
    for number, page in enumerate(page_list):
        texts = [page.paragraph_text(indexes) for indexes in page.paragraphs]
        if not texts:
            page_starts.append(len(document_text))
            continue
        for position, text in enumerate(texts):
            if document_text:
                document_text += " " if (position == 0 and page.continues) else "\n\n"
            if position == 0:
                page_starts.append(len(document_text))
            document_text += text
    return {
        "documentText": document_text,
        "pages": [
            {
                "index": number,
                "kind": page.kind,
                "rotation": page.rotation,
                "startsAt": page_starts[number],
                "lines": page.lines,
            }
            for number, page in enumerate(page_list)
        ],
        "lineHeight": {"ascent": SIZE, "descent": 4},
    }


def write_locked(path):
    import io
    import pypdf

    single = HERE / "_single.pdf"
    write_pdf(single, [pages[0]])
    writer = pypdf.PdfWriter(clone_from=pypdf.PdfReader(str(single)))
    writer.pdf_header = b"%PDF-1.6"  # AES-128 needs 1.6; the clone would keep the 1.4 of the source
    writer.encrypt(user_password="open-sesame", owner_password="owner-only", algorithm="AES-128")
    buffer = io.BytesIO()
    writer.write(buffer)
    path.write_bytes(buffer.getvalue())
    single.unlink()


if __name__ == "__main__":
    write_pdf(HERE / "margin-placement.pdf", pages)
    (HERE / "margin-placement.json").write_text(json.dumps(manifest(pages), indent=1) + "\n")
    write_locked(HERE / "locked.pdf")
    print("ok")
