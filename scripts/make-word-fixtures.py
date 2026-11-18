#!/usr/bin/env python3
"""Writes the Word fixtures for the .docx import tests (#4594) to Contracts/fixtures/word/.

Every file is built here from public-domain text (Lincoln, Thoreau, Austen), so the bytes are ours to commit. The
output is deterministic: run it again and git shows no change. Run from the repository root:

    python3 scripts/make-word-fixtures.py
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Contracts" / "fixtures" / "word"
STAMP = (2026, 11, 18, 0, 0, 0)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS = (
    f'xmlns:w="{W}" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
    'xmlns:v="urn:schemas-microsoft-com:vml"'
)

GETTYSBURG = [
    "Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, "
    "and dedicated to the proposition that all men are created equal.",
    "Now we are engaged in a great civil war, testing whether that nation, or any nation so conceived and so dedicated, "
    "can long endure. We are met on a great battle-field of that war. We have come to dedicate a portion of that field, "
    "as a final resting place for those who here gave their lives that that nation might live. It is altogether fitting "
    "and proper that we should do this.",
    "But, in a larger sense, we can not dedicate, we can not consecrate, we can not hallow this ground. The brave men, "
    "living and dead, who struggled here, have consecrated it, far above our poor power to add or detract.",
]


def esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def run(text: str) -> str:
    return f'<w:r><w:t xml:space="preserve">{esc(text)}</w:t></w:r>'


def para(text: str = "", style: str | None = None, extra_ppr: str = "", runs: str | None = None) -> str:
    ppr = ""
    if style or extra_ppr:
        ppr = "<w:pPr>" + (f'<w:pStyle w:val="{style}"/>' if style else "") + extra_ppr + "</w:pPr>"
    return f"<w:p>{ppr}{runs if runs is not None else (run(text) if text else '')}</w:p>"


def document(body: str) -> str:
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:document {NS}><w:body>{body}<w:sectPr/></w:body></w:document>'


def styles(entries: list[tuple[str, str, int | None]]) -> str:
    """(styleId, name, outline level or None)."""
    parts = ['<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>']
    for style_id, name, level in entries:
        outline = f'<w:pPr><w:outlineLvl w:val="{level}"/></w:pPr>' if level is not None else ""
        parts.append(
            f'<w:style w:type="paragraph" w:styleId="{style_id}"><w:name w:val="{name}"/>'
            f'<w:basedOn w:val="Normal"/>{outline}</w:style>'
        )
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:styles xmlns:w="{W}">{"".join(parts)}</w:styles>'


def core(title: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        f"<dc:title>{esc(title)}</dc:title><dc:creator>Spoken Margins fixtures</dc:creator></cp:coreProperties>"
    )


def content_types(parts: list[str]) -> str:
    overrides = {
        "word/document.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        "word/styles.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
        "word/comments.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml",
        "word/footnotes.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml",
        "docProps/core.xml": "application/vnd.openxmlformats-package.core-properties+xml",
    }
    body = "".join(f'<Override PartName="/{p}" ContentType="{overrides[p]}"/>' for p in parts if p in overrides)
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        f"{body}</Types>"
    )


def package_rels(has_core: bool) -> str:
    core_rel = (
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
        'Target="docProps/core.xml"/>'
        if has_core
        else ""
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        f'Target="word/document.xml"/>{core_rel}</Relationships>'
    )


def document_rels(parts: list[str]) -> str:
    kinds = {
        "word/styles.xml": "styles",
        "word/comments.xml": "comments",
        "word/footnotes.xml": "footnotes",
    }
    rels = "".join(
        f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/{kinds[p]}" '
        f'Target="{p.removeprefix("word/")}"/>'
        for i, p in enumerate((p for p in parts if p in kinds), start=10)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{rels}</Relationships>'
    )


def write_docx(name: str, body: str, *, title: str | None = None, style_xml: str | None = None,
               extra: dict[str, str] | None = None) -> None:
    files: dict[str, str] = {"word/document.xml": document(body)}
    if style_xml:
        files["word/styles.xml"] = style_xml
    if title is not None:
        files["docProps/core.xml"] = core(title)
    files.update(extra or {})
    parts = list(files)
    files["[Content_Types].xml"] = content_types(parts)
    files["_rels/.rels"] = package_rels("docProps/core.xml" in files)
    files["word/_rels/document.xml.rels"] = document_rels(parts)
    path = OUT / name
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for part in sorted(files):
            info = zipfile.ZipInfo(part, date_time=STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, files[part])


WORD_STYLES = styles([
    ("Title", "Title", None),
    ("Heading1", "heading 1", 0),
    ("Heading2", "heading 2", 1),
    ("ListParagraph", "List Paragraph", None),
])


def compound_file(stream_name: str | None) -> bytes:
    """The OLE compound file header, as an old .doc and an encrypted .docx begin, with one directory entry name."""
    header = bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + bytes(504)
    directory = bytearray(512)
    if stream_name:
        name = stream_name.encode("utf-16-le")
        directory[: len(name)] = name
    return header + bytes(directory)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    write_docx("plain-paragraphs.docx", "".join(para(p) for p in GETTYSBURG),
               title="The Gettysburg Address", style_xml=WORD_STYLES)

    write_docx("headings-and-lists.docx", "".join([
        para("Walden", "Title"),
        para("Economy", "Heading1"),
        para("When I wrote the following pages, or rather the bulk of them, I lived alone, in the woods, a mile from any neighbor."),
        para("Shelter", "Heading2"),
        para("Food", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'),
        para("Clothing", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'),
        para("Fuel", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'),
        para("Where I Lived, and What I Lived For", "Heading1"),
        para("I went to the woods because I wished to live deliberately, to front only the essential facts of life."),
        para("Sounds", "Heading1"),
        para("But while we are confined to books, though the most select and classic, we are in danger of forgetting the language which all things and events speak without metaphor."),
    ]), style_xml=WORD_STYLES)

    # Word in German names Heading 1 "berschrift1"; only its outline level says it is a heading.
    write_docx("localized-headings.docx", "".join([
        para("Erstes Kapitel", "berschrift1"),
        para("It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."),
        para("Zweites Kapitel", "berschrift1"),
        para("Mr. Bennet was among the earliest of those who waited on Mr. Bingley."),
    ]), style_xml=styles([("berschrift1", "Überschrift 1", 0)]))

    cell = lambda text: f"<w:tc>{para(text)}</w:tc>"  # noqa: E731
    write_docx("table.docx", "".join([
        para("Thoreau kept an account of what his house cost him."),
        "<w:tbl>"
        f"<w:tr>{cell('Boards')}{cell('$8.03½')}</w:tr>"
        f"<w:tr>{cell('Refuse shingles for roof and sides')}{cell('4.00')}</w:tr>"
        f"<w:tr>{cell('Two second-hand windows with glass')}{cell('2.43')}</w:tr>"
        "</w:tbl>",
        para("In all, twenty-eight dollars and twelve and a half cents."),
    ]))

    write_docx("tracked-changes.docx", "".join([
        para(runs=run("Four score and seven years ago our ")
             + '<w:del w:id="1" w:author="Editor"><w:r><w:delText>grandfathers</w:delText></w:r></w:del>'
             + '<w:ins w:id="2" w:author="Editor">' + run("fathers") + "</w:ins>"
             + run(" brought forth on this continent, a new nation.")),
        para(runs='<w:moveFrom w:id="3" w:author="Editor">' + run("We are met on a great battle-field of that war.") + "</w:moveFrom>"),
        para(runs=run("Now we are engaged in a great civil war. ")
             + '<w:moveTo w:id="4" w:author="Editor">' + run("We are met on a great battle-field of that war.") + "</w:moveTo>"),
    ]))

    write_docx("comments.docx", "".join([
        para(runs='<w:commentRangeStart w:id="0"/>' + run("The world will little note, nor long remember what we say here, but it can never forget what they did here.")
             + '<w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r>'),
    ]), extra={"word/comments.xml":
               f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:comments xmlns:w="{W}">'
               '<w:comment w:id="0" w:author="Professor"><w:p><w:r><w:t>A reviewer comment that must not be read aloud.</w:t></w:r></w:p></w:comment>'
               "</w:comments>"})

    write_docx("footnotes.docx", "".join([
        para(runs=run("I went to the woods because I wished to live deliberately.")
             + '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="1"/></w:r>'
             + run(" I wanted to live deep and suck out all the marrow of life.")),
    ]), extra={"word/footnotes.xml":
               f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:footnotes xmlns:w="{W}">'
               '<w:footnote w:id="1"><w:p><w:r><w:t>Walden Pond, Concord, Massachusetts.</w:t></w:r></w:p></w:footnote>'
               "</w:footnotes>"})

    write_docx("unicode.docx", "".join([
        para("“It is a truth universally acknowledged,” said the narrator — with a smile."),
        para("Café, naïve, Ångström, and the ‘single quotes’ stay as written."),
        para("春眠不覺曉 and שלום sit beside English."),
    ]), title="Smart quotes and Unicode")

    write_docx("markdown-lookalikes.docx", "".join([
        para("# of days in the woods: two years, two months and two days."),
        para("- a dash that opens a line"),
        para("Timestamps were never kept at Walden."),
        para("**Bold** words and a [bracket](like this) stay as text."),
    ]))

    # Word's own placeholder title: the file name wins.
    write_docx("placeholder-title.docx", para(GETTYSBURG[0]), title="Microsoft Word - draft.docx")

    write_docx("text-box.docx", "".join([
        para("Before the box."),
        para(runs='<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wps:txbx><w:txbxContent>'
             + para("Inside the box.") + "</w:txbxContent></wps:txbx></w:drawing></mc:Choice>"
             + '<mc:Fallback><w:pict><v:textbox><w:txbxContent>' + para("Inside the box.")
             + "</w:txbxContent></v:textbox></w:pict></mc:Fallback></mc:AlternateContent></w:r>" + run("After the box, same paragraph.")),
    ]))

    write_docx("empty.docx", para("") + para("   "), title="Nothing here")

    (OUT / "not-a-zip.docx").write_bytes(b"This is a plain text file someone renamed to .docx.\n")
    (OUT / "old-format.doc").write_bytes(compound_file("WordDocument"))
    (OUT / "password-protected.docx").write_bytes(compound_file("EncryptedPackage"))

    print(f"wrote {len(list(OUT.iterdir()))} files to {OUT.relative_to(OUT.parent.parent.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
