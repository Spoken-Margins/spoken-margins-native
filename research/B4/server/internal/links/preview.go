// Package links holds shared Margins packets behind short links for 30 days
// and renders the page someone without the app sees (#486).
//
// Privacy rules this package enforces, not just documents:
//   - A link id is 128 random bits; nothing else names a link, and nothing
//     but the owner's takedown and the page's report button refers to one.
//   - The page shows only what the sender's preview carries: Margin text, a
//     short source excerpt either side (at most 500 characters, the packet's
//     own anchor cap), the source title and show, and a link to the public
//     source. Never source audio.
//   - A source URL that could carry a token (a query, a fragment, userinfo)
//     is dropped when the link is made and again when the page is drawn.
package links

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"unicode/utf8"
)

const (
	PreviewSchema = "spokenmargins.link-preview.v1"

	// MaxPreviewBytes caps the preview's JSON: room for a few Margins, each
	// with two 500-character excerpts.
	MaxPreviewBytes = 16 << 10
	// MaxPacketBytes caps the packet, which carries spoken Margins' audio.
	MaxPacketBytes = 20 << 20
	// MaxExcerptChars is BoundedAnchorContext.maximumCharactersPerSide, the
	// cap SessionKitSharing enforces on a packet's anchor prefix and suffix.
	// It is counted here in Unicode scalars, which is never fewer than
	// Swift's characters, so the app should cut excerpts by unicodeScalars.
	MaxExcerptChars = 500
	// maxTitleChars bounds the source title and show line on the page.
	maxTitleChars = 300
)

// Preview is what the page shows. The app builds it from the packet it is
// sharing, so the server never has to open the packet.
type Preview struct {
	Schema  string   `json:"schema"`
	Source  Source   `json:"source"`
	Margins []Margin `json:"margins"`
}

type Source struct {
	Title string `json:"title"`
	Show  string `json:"show,omitempty"`
	// URL is the public source, linked from the page. Empty when the app had
	// none, or when it could carry a token (see PublicSourceURL).
	URL string `json:"url,omitempty"`
}

// Margin is one Margin's text with the source text either side of where it
// was made. A spoken Margin with no transcript has empty text.
type Margin struct {
	Text   string `json:"text"`
	Before string `json:"before,omitempty"`
	After  string `json:"after,omitempty"`
}

var ErrBadPreview = errors.New("links: bad preview")

func bad(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrBadPreview, fmt.Sprintf(format, args...))
}

// ParsePreview checks a preview and returns it with any token-carrying
// source URL removed. Every rule here has a test in preview_test.go.
func ParsePreview(data []byte) (Preview, error) {
	var p Preview
	if len(data) > MaxPreviewBytes {
		return p, bad("over %d bytes", MaxPreviewBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return p, bad("%v", err)
	}
	if dec.More() {
		return p, bad("trailing data")
	}
	if p.Schema != PreviewSchema {
		return p, bad("schema %q", p.Schema)
	}
	if strings.TrimSpace(p.Source.Title) == "" {
		return p, bad("no source title")
	}
	for name, v := range map[string]string{"title": p.Source.Title, "show": p.Source.Show, "url": p.Source.URL} {
		if !utf8.ValidString(v) {
			return p, bad("source %s is not UTF-8", name)
		}
	}
	if utf8.RuneCountInString(p.Source.Title) > maxTitleChars || utf8.RuneCountInString(p.Source.Show) > maxTitleChars {
		return p, bad("source title or show over %d characters", maxTitleChars)
	}
	if len(p.Margins) == 0 {
		return p, bad("no Margins")
	}
	for i, m := range p.Margins {
		if !utf8.ValidString(m.Text) || !utf8.ValidString(m.Before) || !utf8.ValidString(m.After) {
			return p, bad("Margin %d is not UTF-8", i)
		}
		if utf8.RuneCountInString(m.Before) > MaxExcerptChars || utf8.RuneCountInString(m.After) > MaxExcerptChars {
			return p, bad("Margin %d has an excerpt over %d characters", i, MaxExcerptChars)
		}
	}
	p.Source.URL = PublicSourceURL(p.Source.URL)
	return p, nil
}

// PublicSourceURL returns raw if it is safe to link from a public page: an
// http or https address with a host and nothing that could carry a private
// token (no query, fragment or userinfo). Otherwise it returns "", so the
// page shows the title without a link rather than a cleaned-up guess.
func PublicSourceURL(raw string) string {
	if raw == "" || len(raw) > 2048 {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.Opaque != "" {
		return ""
	}
	if u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || strings.ContainsAny(raw, "?#") {
		return ""
	}
	return raw
}
