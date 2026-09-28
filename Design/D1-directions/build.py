#!/usr/bin/env python3
"""Inline the shared engine, CSS and icons into each direction page.

Writes two copies of each page:
  Design/D1-directions/<name>.html   full document, opens from the repo or any static host
  <out>/<name>.html                  fragment for publishing as a Claude artifact (no doctype/head)
"""
import pathlib, sys

here = pathlib.Path(__file__).resolve().parent
src = here / "src"
out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
parts = {
    "{{SHARED_CSS}}": (src / "shared.css").read_text(),
    "{{ENGINE}}": (src / "engine.js").read_text(),
    "{{ICONS}}": (src / "icons.svg").read_text(),
}
HEAD = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n')
for page in sorted(src.glob("[abc]-*.html")):
    text = page.read_text()
    for k, v in parts.items():
        text = text.replace(k, v)
    assert "{{" not in text, page
    # The page source starts with <title>, <link> and <style>; everything after
    # the first </style> is body content.
    head, body = text.split("</style>", 1)
    (here / page.name).write_text(HEAD + head + "</style>\n</head>\n<body>" + body + "</body>\n</html>\n")
    if out:
        out.mkdir(parents=True, exist_ok=True)
        (out / page.name).write_text(text)
    print("built", page.name)
