package clubs

import (
	"embed"
	"errors"
	"html/template"
	"io"

	"spokenmargins.dev/bridge/internal/links"
)

// The page a club invite opens in a browser (#1799, docs/design/club-mailbox.md section 10, slice 4).
//
// The server sends one shell for every club id of the right shape, and it never looks the club up. The page
// that says "you're invited" is therefore the same for a club that exists, one that ended and an id nobody
// made, so the public path part names nothing (the same rule as every other club answer, section 5). The
// key is in the address's # part, which no browser sends; this server cannot read it. The one script,
// club-page.mjs, reads the # part in the browser to build the "Open in Spoken Margins" address, and makes no
// request.

// The page is a few plain paragraphs and two links: get the app, and open the invite in it. The open button
// is hidden until the script has found a key to hand over, so there is never a button that opens the app
// with no way to join. The status line starts with words that stand alone, and the script replaces them, so a
// script that never loads (JavaScript off, a blocked or failed fetch) leaves a reader with the next step.
var page = template.Must(template.New("club").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow"><title>Club invitation — Spoken Margins</title>
<style>body{font:17px/1.6 system-ui,sans-serif;margin:0;background:#faf9f6;color:#252524}main{max-width:42rem;margin:auto;padding:1.5rem}a{color:#305d78}.button{display:inline-block;padding:.6rem 1rem;border:1px solid #305d78;border-radius:.6rem;text-decoration:none}[hidden]{display:none}</style>
<script type="module" src="/c/club-page.mjs"></script></head>
<body><main id="club" data-club="{{.ID}}"><header><p>Spoken Margins</p><h1>You're invited to a club</h1></header>
<p>A club is a shared box of Margins. Friends add their own, and each of you hears them at the right place in your own copy of the article or podcast.</p>
<p>The box is locked. The key is in this invite link, in the part after the #, which your browser never sends to us. We can't open it, and we don't know who is in a club.</p>
<p>Anyone who has this link can read the club and add to it, so pass it only to people you want in.</p>
<p id="status" role="status">If the button does not appear, tap the invite link in your message again once Spoken Margins is installed.</p>
<p><a id="open" class="button" href="spokenmargins://club" hidden>Open in Spoken Margins</a></p>
{{if .InstallURL}}<p>New here? <a href="{{.InstallURL}}" rel="noreferrer noopener">Get Spoken Margins</a>, then tap the invite link in your message again.</p>{{end}}
<footer><p>{{range $i, $l := .Policies}}{{if $i}} · {{end}}<a href="{{$l.Path}}">{{$l.Title}}</a>{{end}}</p></footer>
</main></body></html>`))

// Render writes the invitation shell for one club id. installURL is the one the share-link page offers; an
// invalid or empty one leaves the install sentence out rather than failing the page.
func Render(w io.Writer, id, installURL string) error {
	if !ValidID(id) {
		return errors.New("clubs: invalid club id")
	}
	if !links.ValidInstallURL(installURL) {
		installURL = ""
	}
	return page.Execute(w, struct {
		ID, InstallURL string
		Policies       []links.PolicyLink
	}{id, installURL, links.PolicyLinks})
}

// Unavailable is why an invitation page has nothing to show. An id that was never a club's and a club that
// ended are never told apart: both get the invitation shell, and only an address that cannot be a club's reads
// "isn't available".
type Unavailable int

const (
	// UnavailableMalformed is an address that cannot be a club's.
	UnavailableMalformed Unavailable = iota
	// UnavailablePaused is the clubs switch being off.
	UnavailablePaused
)

var unavailableWords = map[Unavailable]struct{ Heading, Body string }{
	UnavailableMalformed: {"This invite isn't available", "The address looks cut off or mistyped. Copy the whole link from your message and open it again, or ask your friend to send it again."},
	UnavailablePaused:    {"Clubs are paused", "Try this invite again later, or ask your friend to send the Margins another way."},
}

var unavailable = template.Must(template.New("clubUnavailable").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow"><title>{{.Heading}} — Spoken Margins</title>
<style>body{font:17px/1.6 system-ui,sans-serif;margin:0;background:#faf9f6;color:#252524}main{max-width:42rem;margin:auto;padding:1.5rem}a{color:#305d78}</style></head>
<body><main><header><p>Spoken Margins</p><h1>{{.Heading}}</h1></header><p>{{.Body}}</p>
<footer><p>{{range $i, $l := .Policies}}{{if $i}} · {{end}}<a href="{{$l.Path}}">{{$l.Title}}</a>{{end}}</p></footer>
</main></body></html>`))

// RenderUnavailable writes the plain page for an invite address that cannot be shown.
func RenderUnavailable(w io.Writer, reason Unavailable) error {
	words, ok := unavailableWords[reason]
	if !ok {
		return errors.New("clubs: unknown unavailable reason")
	}
	return unavailable.Execute(w, struct {
		Heading, Body string
		Policies      []links.PolicyLink
	}{words.Heading, words.Body, links.PolicyLinks})
}

// The browser half of the page.
//
//go:embed club-page.mjs
var pageScripts embed.FS

// PageScript returns the page's one module by file name.
func PageScript(name string) ([]byte, bool) {
	if name != "club-page.mjs" {
		return nil, false
	}
	data, err := pageScripts.ReadFile(name)
	return data, err == nil
}
