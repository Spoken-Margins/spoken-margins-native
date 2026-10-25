package links

import (
	"bytes"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"net/url"
	"strings"
	"unicode/utf8"
)

// The share page's excerpt caps (owner, 2026-10-20, D16 in docs/legal/attorney-questions.md; #2237). They are the
// ceilings of the app's ExcerptCapRule (Packages/SessionKit/Sources/SessionKit/ExcerptCapRule.swift), which scales the
// "before" side to the comment (280 to 800 characters) and holds the "after" side to 120. The server checks only the
// ceilings, in Unicode code points; the app also keeps every excerpt under its cap in code points. Builds 32 and 34
// reject a packet whose context runs over 500 per side, so the "before" ceiling stays at 500 here and in the app
// until those builds are retired (the same text goes into the packet and the page).
const (
	MaxBeforeCharacters = 500
	MaxAfterCharacters  = 120
)

type Margin struct {
	Text   string `json:"text"`
	Before string `json:"before"`
	After  string `json:"after"`
}
type Source struct {
	Title string `json:"title"`
	Show  string `json:"show"`
	URL   string `json:"url"`
}
type Preview struct {
	Source  Source   `json:"source"`
	Margins []Margin `json:"margins"`
}

func ParsePreview(data []byte) (Preview, error) {
	var p Preview
	if len(data) > MaxPreviewBytes {
		return p, ErrTooLarge
	}
	if !utf8.Valid(data) {
		return p, errors.New("links: invalid UTF-8")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return p, err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return p, errors.New("links: trailing JSON")
	}
	if len(p.Margins) == 0 || strings.TrimSpace(p.Source.Title) == "" {
		return p, errors.New("links: missing preview")
	}
	for _, m := range p.Margins {
		if utf8.RuneCountInString(m.Before) > MaxBeforeCharacters || utf8.RuneCountInString(m.After) > MaxAfterCharacters {
			return p, errors.New("links: excerpt too long")
		}
	}
	return p, nil
}

// SafeSourceURL omits URLs that could disclose signed queries or credentials.
// Nothing from an unsafe URL is inserted into either an attribute or page text.
func SafeSourceURL(raw string) string {
	if strings.TrimSpace(raw) != raw {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Opaque != "" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawFragment != "" ||
		(u.Scheme != "https" && u.Scheme != "http") {
		return ""
	}
	return u.String()
}

// InstallURL must be a real app listing or a TestFlight invitation supplied by
// the owner, never a guessed listing or an arbitrary redirect on the page.
func ValidInstallURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Port() != "" {
		return false
	}
	return (u.Host == "testflight.apple.com" && strings.HasPrefix(u.Path, "/join/") && len(strings.TrimPrefix(u.Path, "/join/")) > 0) ||
		(u.Host == "apps.apple.com" && strings.Contains(u.Path, "/id"))
}

var landing = template.Must(template.New("landing").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Shared Margins — Spoken Margins</title>
<style>body{font:17px/1.6 system-ui,sans-serif;margin:0;background:#faf9f6;color:#252524}main{max-width:42rem;margin:auto;padding:1.5rem}article{margin:2rem 0;padding:1rem;background:white;border:1px solid #ddd;border-radius:.7rem}blockquote{margin:1rem 0;border-left:3px solid #aaa;padding-left:1rem}p{white-space:pre-wrap;overflow-wrap:anywhere}a{color:#305d78}button,select{font:inherit;padding:.5rem;max-width:100%}small{color:#555}</style></head>
<body><main><header><p>Spoken Margins</p><h1>Shared Margins</h1><p>These Margins are available for 30 days. Source audio is not served here.</p></header>
{{range .Preview.Margins}}<article><h2>Margin</h2><p>{{.Text}}</p><blockquote><small>Quotation from the source · before this Margin</small><p>{{.Before}}</p></blockquote><blockquote><small>Quotation from the source · after this Margin</small><p>{{.After}}</p></blockquote><footer><p><strong>{{$.Preview.Source.Title}}</strong>{{if $.Preview.Source.Show}}<br>{{$.Preview.Source.Show}}{{end}}</p>{{if $.SourceURL}}<a href="{{$.SourceURL}}" rel="noreferrer noopener">Open public source</a>{{end}}</footer></article>{{end}}
<p><a href="{{.InstallURL}}" rel="noreferrer noopener">Install Spoken Margins (App Store / TestFlight)</a></p>
<form method="post" action="/l/{{.ID}}/report"><label for="reason">Reason for reporting</label> <select id="reason" name="reason" required><option value="privacy">Privacy concern</option><option value="copyright">Copyright concern</option><option value="harmful">Harmful content</option><option value="spam">Spam</option><option value="other">Other concern</option></select> <button type="submit">Report this link</button></form>
</main></body></html>`))

func Render(w io.Writer, id string, p Preview, installURL string) error {
	if !ValidID(id) || !ValidInstallURL(installURL) {
		return errors.New("links: invalid page configuration")
	}
	return landing.Execute(w, struct {
		ID         string
		Preview    Preview
		SourceURL  string
		InstallURL string
	}{id, p, SafeSourceURL(p.Source.URL), installURL})
}
