"""Converts publisher ground truth into role-labelled segments.

Output shape (one JSON file per corpus entry, `cache/gt/<id>.json`):

    {"id": ..., "kind": "jats" | "latexml",
     "segments": [{"role": ..., "text": ..., "markers": [...], "label": ...}]}

Roles follow the I13 draft (research/C1/I13/): title, heading, abstract, body,
caption, table, footnote, equation, reference, front_matter, back_matter.
Inline citation and footnote markers are taken *out* of body text and kept
as markers with the character offset where they sat, so the scorer can see
how an extractor rendered each one. Inline math becomes a marker too:
LaTeX source and MathML never match what a PDF shows, so it is neither body
text nor clutter in the score.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from lxml import etree, html as lxml_html

BLOCK_ROLES = {"title", "heading", "abstract", "body", "caption", "table", "footnote",
               "equation", "reference", "front_matter", "back_matter"}


@dataclass
class Segment:
    role: str
    text: str = ""
    markers: list = field(default_factory=list)
    label: str | None = None  # e.g. "Figure 2" for captions and tables

    def as_json(self) -> dict:
        out = {"role": self.role, "text": re.sub(r"\s+", " ", self.text).strip()}
        if self.markers:
            # Offsets were recorded on the raw text; recompute on the collapsed text.
            out["markers"] = self.markers
        if self.label:
            out["label"] = self.label
        return out


class Builder:
    """Accumulates inline text for the current block, then emits a segment."""

    def __init__(self):
        self.segments: list[Segment] = []
        self.stack: list[Segment] = []

    def open(self, role: str, label: str | None = None):
        self.stack.append(Segment(role, label=label))

    def close(self):
        seg = self.stack.pop()
        collapsed, markers = collapse(seg.text, seg.markers)
        seg.text, seg.markers = collapsed, markers
        if seg.text or seg.markers:
            self.segments.append(seg)

    @property
    def current(self) -> Segment | None:
        return self.stack[-1] if self.stack else None

    def text(self, value: str | None):
        if value and self.current is not None:
            self.current.text += value

    def marker(self, kind: str, label: str):
        if self.current is not None:
            self.current.markers.append({"kind": kind, "label": " ".join(label.split()), "at": len(self.current.text)})
            # Keep words on either side of a marker apart.
            self.current.text += " "


def collapse(text: str, markers: list) -> tuple[str, list]:
    """Collapses whitespace while keeping marker offsets pointing at the same spot."""
    out = []
    mapping = []
    previous_space = True
    for ch in text:
        mapping.append(len(out))
        if ch.isspace():
            if not previous_space:
                out.append(" ")
            previous_space = True
        else:
            out.append(ch)
            previous_space = False
    mapping.append(len(out))
    collapsed = "".join(out)
    stripped = collapsed.rstrip()
    moved = []
    for marker in markers:
        at = min(mapping[marker["at"]], len(stripped))
        moved.append({**marker, "at": at})
    lead = len(stripped) - len(stripped.lstrip())
    if lead:
        moved = [{**m, "at": max(0, m["at"] - lead)} for m in moved]
    return stripped.strip(), moved


def is_narrative_citation(label: str, before: str) -> bool:
    """"Smith et al. (2020) showed" is part of the sentence and stays body text.
    Numeric markers and citations inside brackets or parentheses are markers."""
    label = label.strip()
    if not label or label[0] in "([" or re.fullmatch(r"[\d\s,–\-]+[a-z]?", label):
        return False
    tail = before.rstrip()[-60:]
    inside = max(tail.rfind("("), tail.rfind("[")) > max(tail.rfind(")"), tail.rfind("]"))
    return not inside


# ---------------------------------------------------------------- JATS -----

MML = "{http://www.w3.org/1998/Math/MathML}"
FRONT_SKIP = {"article-categories", "self-uri", "related-article", "counts", "custom-meta-group"}


def local(tag) -> str:
    if not isinstance(tag, str):
        return ""
    return tag.split("}", 1)[-1]


def jats_segments(xml: bytes) -> list[dict]:
    parser = etree.XMLParser(recover=True, resolve_entities=False, no_network=True, huge_tree=True)
    root = etree.fromstring(xml, parser)
    b = Builder()
    article = root if local(root.tag) == "article" else root.find(".//article")
    if article is None:
        article = root

    meta = article.find("./front/article-meta")
    if meta is not None:
        title = meta.find("./title-group/article-title")
        if title is not None:
            b.open("title")
            jats_inline(b, title)
            b.close()
        for child in meta:
            name = local(child.tag)
            if name in ("title-group",) or name in FRONT_SKIP:
                continue
            if name == "abstract" or name == "trans-abstract":
                if name == "trans-abstract" or child.get("abstract-type") in ("graphical", "teaser", "toc"):
                    jats_block(b, child, "front_matter")
                else:
                    b.open("heading")
                    b.text("Abstract")
                    b.close()
                    jats_block(b, child, "abstract")
            else:
                jats_block(b, child, "front_matter")
    body = article.find("./body")
    if body is not None:
        jats_block(b, body, "body")
    back = article.find("./back")
    if back is not None:
        for child in back:
            name = local(child.tag)
            if name == "ref-list":
                jats_block(b, child, "reference")
            elif name == "fn-group":
                jats_block(b, child, "footnote")
            elif name == "app-group":
                jats_block(b, child, "body")
            else:
                jats_block(b, child, "back_matter")
    # Reviewer reports, decision letters and author responses (eLife, F1000)
    # are printed in some PDFs but aren't the paper.
    for sub in article.findall("./sub-article"):
        for child in sub:
            jats_block(b, child, "back_matter")
    return [s.as_json() for s in b.segments]


def label_of(el) -> str | None:
    label = el.find("./label")
    return " ".join("".join(label.itertext()).split()) if label is not None else None


def jats_block(b: Builder, el, role: str):
    """Walks a block container, emitting one segment per paragraph-like element."""
    name = local(el.tag)
    if name in ("sec", "abstract", "ack", "app", "boxed-text", "notes", "glossary", "back", "body", "app-group",
                "ref-list", "fn-group", "trans-abstract", "funding-group", "author-notes", "def-list", "list",
                "disp-quote", "statement", "custom-meta-group", "kwd-group", "history", "permissions",
                "contrib-group", "fig-group"):
        for child in el:
            cname = local(child.tag)
            if cname == "title":
                b.open("heading" if role in ("body", "abstract", "back_matter", "reference", "footnote") else role)
                if role == "front_matter":
                    b.current.role = "front_matter"
                label = label_of(el)
                if label:
                    b.text(label + " ")
                jats_inline(b, child)
                b.close()
            elif cname == "label":
                continue
            elif cname == "sec-meta":
                continue
            else:
                jats_block(b, child, role)
        return
    if name in ("fig", "table-wrap", "supplementary-material", "media", "chem-struct-wrap"):
        jats_float(b, el, role)
        return
    if name == "disp-formula":
        b.open("equation")
        b.text(" ".join(el.itertext()))
        b.close()
        return
    if name in ("ref",):
        b.open("reference")
        jats_inline(b, el)
        b.close()
        return
    if name == "fn":
        b.open("footnote" if role not in ("front_matter", "table") else role)
        jats_inline(b, el)
        b.close()
        return
    if name in ("list-item", "def-item"):
        for child in el:
            jats_block(b, child, role)
        return
    if name in ("p", "title", "kwd", "aff", "contrib", "date", "pub-date", "copyright-statement", "license",
                "license-p", "corresp", "funding-statement", "award-group", "term", "def", "attrib",
                "article-id", "volume", "issue", "fpage", "lpage", "elocation-id", "copyright-year",
                "copyright-holder", "funding-source", "award-id", "principal-award-recipient", "mixed-citation",
                "element-citation", "author-comment", "x", "subject", "graphic", "alternatives", "code",
                "preformat", "verse-group", "string-name", "ext-link", "uri", "email", "issn", "isbn",
                "publisher", "conference", "trans-title-group", "product", "supplement", "volume-issue-group",
                "pub-history", "related-object"):
        para_role = role
        if name == "graphic":
            return
        b.open(para_role)
        jats_inline(b, el)
        b.close()
        return
    # Unknown containers: recurse.
    for child in el:
        jats_block(b, child, role)


def jats_float(b: Builder, el, role: str):
    label = label_of(el)
    caption = el.find("./caption")
    name = local(el.tag)
    if name == "supplementary-material":
        b.open("back_matter")
        jats_inline(b, el)
        b.close()
        return
    b.open("caption", label=label)
    if label:
        b.text(label + " ")
    if caption is not None:
        for child in caption:
            if local(child.tag) in ("title", "p"):
                jats_inline(b, child)
                b.text(" ")
    b.close()
    if name == "table-wrap":
        for table in el.iter():
            if local(table.tag) in ("table", "table-wrap-foot"):
                b.open("table", label=label)
                for cell in table.iter():
                    if local(cell.tag) in ("td", "th", "fn", "p") and cell.getparent() is not None:
                        if local(cell.tag) in ("td", "th", "fn"):
                            b.text(" " + " ".join(cell.itertext()) + " ")
                b.close()
    for fig in el:
        if local(fig.tag) in ("fig", "table-wrap"):
            jats_float(b, fig, role)


# Elements JATS runs together ("<surname>Li</surname><given-names>Wei</given-names>").
NAME_PARTS = {"surname", "given-names", "prefix", "suffix", "name", "string-name", "institution", "addr-line",
              "country", "city", "state", "postal-code", "collab", "degrees", "role", "year", "source",
              "article-title", "volume", "fpage", "lpage", "person-group", "etal", "pub-id", "issue"}

BLOCK_IN_PARA = {"fig", "table-wrap", "disp-formula", "list", "boxed-text", "disp-quote", "fig-group",
                 "supplementary-material", "def-list", "table-wrap-group", "statement", "code", "preformat"}


def jats_inline(b: Builder, el):
    """Adds el's text to the current segment, splitting out markers and blocks."""
    b.text(el.text)
    for child in el:
        name = local(child.tag)
        if name == "xref" and child.get("ref-type") in ("bibr", "fn", "table-fn"):
            label = "".join(child.itertext())
            kind = "citation" if child.get("ref-type") == "bibr" else "footnote"
            seg = b.current
            if kind == "citation" and seg is not None and is_narrative_citation(label, seg.text):
                # Narrative citation: its words are part of the sentence.
                b.text(label)
            else:
                b.marker(kind, label)
        elif name in ("inline-formula", "math") or child.tag == f"{MML}math" or name == "tex-math":
            b.marker("math", "")
        elif name in BLOCK_IN_PARA:
            role = b.current.role if b.current else "body"
            label = b.current.label if b.current else None
            b.close()
            if name == "disp-formula":
                jats_block(b, child, role)
            elif name in ("list", "boxed-text", "disp-quote", "def-list", "statement"):
                jats_block(b, child, role)
            else:
                jats_block(b, child, role)
            b.open(role, label=label)
        elif name in ("fn",):
            role = b.current.role if b.current else "body"
            b.marker("footnote", label_of(child) or "")
            b.close()
            b.open("footnote")
            jats_inline(b, child)
            b.close()
            b.open(role)
        elif name == "label" and local(el.tag) in ("fn", "ref", "list-item"):
            b.text(" ".join(child.itertext()) + " ")
        elif name in ("object-id", "alt-text", "long-desc", "graphic", "inline-graphic"):
            pass
        else:
            jats_inline(b, child)
            if name in NAME_PARTS:
                b.text(" ")
        b.text(child.tail)


# ------------------------------------------------------------- LaTeXML -----

def classes(el) -> set[str]:
    return set((el.get("class") or "").split())


def latexml_segments(html: bytes) -> list[dict]:
    doc = lxml_html.fromstring(html)
    article = doc.find(".//article")
    if article is None:
        article = doc.body
    b = Builder()
    latexml_block(b, article, "body")
    return [s.as_json() for s in b.segments]


SKIP_CLASSES = {"ltx_TOC", "ltx_page_navbar", "ltx_page_footer", "ltx_page_header", "ltx_ERROR",
                "ltx_role_newpage", "ltx_pagination", "ltx_rdf", "ltx_dates"}


def latexml_block(b: Builder, el, role: str):
    c = classes(el)
    tag = el.tag if isinstance(el.tag, str) else ""
    if c & SKIP_CLASSES or tag in ("nav", "script", "style", "button"):
        return
    if "ltx_title_document" in c:
        b.open("title")
        latexml_inline(b, el)
        b.close()
        return
    if "ltx_authors" in c or "ltx_keywords" in c or "ltx_classification" in c or "ltx_date" in c:
        b.open("front_matter")
        latexml_inline(b, el)
        b.close()
        return
    if "ltx_abstract" in c:
        for child in el:
            latexml_block(b, child, "abstract")
        return
    if "ltx_bibliography" in c:
        for child in el:
            cc = classes(child)
            if "ltx_title" in cc:
                b.open("heading")
                latexml_inline(b, child)
                b.close()
            else:
                for item in child.iter("li"):
                    if "ltx_bibitem" in classes(item):
                        b.open("reference")
                        latexml_inline(b, item)
                        b.close()
        return
    if "ltx_acknowledgements" in c or "ltx_acknowledgement" in c:
        b.open("back_matter")
        latexml_inline(b, el)
        b.close()
        return
    if tag in ("h1", "h2", "h3", "h4", "h5", "h6") or ("ltx_title" in c and tag != "span"):
        b.open("heading")
        latexml_inline(b, el)
        b.close()
        return
    if tag == "figure" or "ltx_figure" in c or "ltx_table" in c and tag != "span":
        latexml_float(b, el)
        return
    if "ltx_equation" in c or "ltx_equationgroup" in c or "ltx_eqn_table" in c:
        b.open("equation")
        for math in el.iter("math"):
            b.text(" " + (math.get("alttext") or "") + " ")
        b.close()
        return
    if tag == "p" or "ltx_p" in c:
        b.open(role)
        latexml_inline(b, el)
        b.close()
        return
    if "ltx_section" in c and section_is_back_matter(el):
        for child in el:
            latexml_block(b, child, "back_matter")
        return
    for child in el:
        latexml_block(b, child, role)


BACK_MATTER_TITLES = re.compile(
    r"(?i)^\s*(?:[A-Z0-9.]+\s+)?(acknowledg|funding|author contributions?|competing interests?|conflicts? of interest|"
    r"data availability|code availability|ethics|declaration)")


def section_is_back_matter(el) -> bool:
    for child in el:
        if "ltx_title" in classes(child):
            return bool(BACK_MATTER_TITLES.match(" ".join(child.itertext())))
    return False


def latexml_float(b: Builder, el):
    caption = None
    for node in el.iter():
        if node.tag == "figcaption" or "ltx_caption" in classes(node):
            caption = node
            break
    label = None
    if caption is not None:
        tags = [n for n in caption.iter() if "ltx_tag" in classes(n)]
        if tags:
            label = " ".join("".join(tags[0].itertext()).split()).rstrip(":. ")
        b.open("caption", label=label)
        latexml_inline(b, caption)
        b.close()
    if "ltx_table" in classes(el):
        b.open("table", label=label)
        for cell in el.iter("td", "th"):
            b.text(" " + " ".join(t for t in cell.itertext()) + " ")
        b.close()
    else:
        # Subfigures and in-figure paragraphs (rare) are figure text, not body.
        for node in el.iter("figure"):
            if node is not el and "ltx_table" in classes(node):
                latexml_float(b, node)


def latexml_inline(b: Builder, el):
    b.text(el.text)
    for child in el:
        tag = child.tag if isinstance(child.tag, str) else ""
        c = classes(child)
        if c & SKIP_CLASSES:
            pass
        elif tag == "cite" or "ltx_cite" in c:
            label = " ".join("".join(child.itertext()).split())
            if is_narrative_citation(label, b.current.text if b.current else ""):
                b.text(label)
            else:
                b.marker("citation", label)
        elif "ltx_note" in c and "ltx_role_footnote" in c:
            mark = child.find(".//*[@class='ltx_note_mark']")
            role = b.current.role if b.current else "body"
            b.marker("footnote", "".join(mark.itertext()) if mark is not None else "")
            b.close()
            content = None
            for node in child.iter():
                if "ltx_note_content" in classes(node):
                    content = node
                    break
            if content is not None:
                b.open("footnote")
                for node in content:
                    if "ltx_note_mark" in classes(node) or "ltx_tag" in classes(node):
                        b.text(node.tail)
                        continue
                    b.text(" ")
                    latexml_inline_node(b, node)
                b.close()
            b.open(role)
        elif "ltx_note" in c:
            pass
        elif tag == "math" or "ltx_Math" in c:
            b.marker("math", child.get("alttext") or "")
        elif tag in ("figure", "table") and ("ltx_figure" in c or "ltx_table" in c or "ltx_equation" in c
                                             or "ltx_equationgroup" in c or "ltx_eqn_table" in c):
            role = b.current.role if b.current else "body"
            b.close()
            latexml_block(b, child, role)
            b.open(role)
        elif tag in ("ul", "ol", "div") and b.current is not None:
            role = b.current.role
            b.close()
            latexml_block(b, child, role)
            b.open(role)
        elif tag in ("img", "svg", "button", "script", "style"):
            pass
        elif "ltx_tag_bibitem" in c:
            b.text(" " + "".join(child.itertext()) + " ")
        else:
            latexml_inline(b, child)
        b.text(child.tail)


def latexml_inline_node(b: Builder, node):
    """Inline-walks one node including its own text (used for footnote bodies)."""
    tag = node.tag if isinstance(node.tag, str) else ""
    if tag == "math" or "ltx_Math" in classes(node):
        b.marker("math", node.get("alttext") or "")
    else:
        latexml_inline(b, node)
    b.text(node.tail)
