package links

import (
	_ "embed"
	"html/template"
)

// The preview card a messenger draws when a share link is pasted into Messages, WhatsApp or mail (#5271). A link is
// sealed (#805): the server can't read what it holds, so the card is one constant for every link, live or not. It
// names no sender, show or Margin, and nothing in it is built from the request.
//
// card/preview-tags.html is the single source of the tag block. The Go pages put it in their heads, and
// research/B4/deploy/deploy-web.sh copies it into the web listener's link.html, the page a browser is handed to.

//go:embed card/preview-tags.html
var previewTags string

// PreviewTags is the Open Graph tag block, as HTML that the page templates insert as is.
var PreviewTags = template.HTML(previewTags)

// CardPNG is the 1200 x 630 picture og:image names, rendered from card/card.html and served at /l/card.png.
//
//go:embed card/card.png
var CardPNG []byte
