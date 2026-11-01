package links

import (
	"errors"
	"html/template"
	"io"
	"net/url"
	"strings"
)

// The landing page holds no Margin, excerpt or title: the preview is sealed (#805), so the server
// can't read it. The page is a shell; share-link-page.mjs fetches /l/<id>/preview, opens it with the
// key in location.hash, checks it (the excerpt ceilings, a title, at least one Margin) and fills in
// the Margins as text. The install link and the report form stay server-rendered, so they work
// without the key and without JavaScript.

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
<style>body{font:17px/1.6 system-ui,sans-serif;margin:0;background:#faf9f6;color:#252524}main{max-width:42rem;margin:auto;padding:1.5rem}article{margin:2rem 0;padding:1rem;background:white;border:1px solid #ddd;border-radius:.7rem}blockquote{margin:1rem 0;border-left:3px solid #aaa;padding-left:1rem}p{white-space:pre-wrap;overflow-wrap:anywhere}a{color:#305d78}button,select{font:inherit;padding:.5rem;max-width:100%}small{color:#555}</style>
<script type="module" src="/l/share-link-page.mjs"></script></head>
<body><main><header><p>Spoken Margins</p><h1>Shared Margins</h1><p>These Margins are available for 30 days. Source audio is not served here.</p></header>
<section id="margins" data-link="{{.ID}}"><p id="status" role="status"></p><noscript><p>Turn on JavaScript to read these Margins. They are sealed, and only your browser can open them with the key in the link.</p></noscript></section>
<p><a href="{{.InstallURL}}" rel="noreferrer noopener">Install Spoken Margins (App Store / TestFlight)</a></p>
<form method="post" action="/l/{{.ID}}/report"><h2>Report this link</h2><p>Anyone can report this link. It is taken down at once and nobody reads what it held.</p><p><label for="category">What is wrong?</label> <select id="category" name="category" required><option value="" selected disabled>Choose one</option><option value="intimate_images">Intimate images shared without consent</option><option value="abuse_material">Child sexual abuse material</option><option value="harassment">Harassment or defamation</option><option value="hateful_conduct">Hateful conduct</option><option value="copyright">Copyright (see the copyright page for a formal notice)</option><option value="other">Other</option></select></p><p><label for="link">Only for child sexual abuse material: paste the full link from the address bar, including the part after the #. Leave this empty for everything else.</label> <input id="link" name="link" type="text" maxlength="2048" autocomplete="off"></p> <button type="submit">Report this link</button></form>
</main></body></html>`))

// Render writes the landing page shell for one link.
func Render(w io.Writer, id string, installURL string) error {
	if !ValidID(id) || !ValidInstallURL(installURL) {
		return errors.New("links: invalid page configuration")
	}
	return landing.Execute(w, struct {
		ID         string
		InstallURL string
	}{id, installURL})
}
