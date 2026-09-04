# Safari PDF manual proof — provisional next

State: developer-verified; not product-owner human validation.

- Date: 2026-09-04
- Branch: `codex/provisional-next`
- Simulator: Spoken Margins TestFlight, iOS 26.5
- PDF: `https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf`

## Exact manual route

1. Installed and launched the current Debug build containing `SpokenMarginsShareExtension`.
2. Opened the PDF URL in Safari and observed Safari's native PDF viewer displaying “Dummy PDF file.”
3. Chose **More → Share → Spoken Margins**.
4. Observed the share extension complete and dismiss without an error card.
5. Returned to Spoken Margins and searched the Library for `dummy`.
6. Observed the **Dummy PDF file** row in the Library.
7. Opened that row and observed the Item screen with **Dummy PDF file** and **Start listening**.

## Stored evidence

- Imported item id: `item-browser-dummy-pdf-file-https-www-w3-org-wai-er-tests-xht`
- Media type: `pdf`
- External reference type: `file`
- Extracted text: `Dummy PDF file`
- PDFKit structure: one page
- Safari's temporary property-list handoff was consumed; no pending handoff remained.

Screenshots:

- `safari-pdf-library-arrival.png`
- `safari-pdf-item-open.png`

## Falsification path caught

Earlier automated representation tests did not establish that Safari could discover the extension, execute its preprocessor, or supply usable PDF metadata. Manual navigation found three distinct failures: the activation dictionary excluded Safari's PDF representation set; the required `ExtensionPreprocessingJS` global instance was missing; and webpage extraction was selected before PDF URL detection, importing Safari viewer CSS. This proof was repeated after all three were corrected.
