package links

import (
	"html/template"
	"io"
	"strings"
)

// Report reasons the page offers. Anything else is recorded as "other".
var ReportReasons = []struct{ Value, Label string }{
	{"spam", "Spam or advertising"},
	{"harmful", "Harassment, hate or other harm"},
	{"rights", "Copyright or other rights"},
	{"personal", "Shares someone's personal information"},
	{"other", "Something else"},
}

// ReportReason returns value if it is one of ReportReasons, else "other",
// so the abuse log only ever holds a word from this list.
func ReportReason(value string) string {
	for _, r := range ReportReasons {
		if r.Value == value {
			return value
		}
	}
	return "other"
}

// PageCSP is the page's Content-Security-Policy: no scripts, no outside
// loads, and the report form may only post back here.
const PageCSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

// Page is everything the link page shows.
type Page struct {
	ID         string
	Link       Link
	InstallURL string
}

type pageView struct {
	ID         string
	Source     Source
	SourceURL  string
	Margins    []Margin
	Expires    string
	InstallURL string
	Reasons    any
}

// RenderPage writes the link's page: self-contained HTML with no script,
// every value escaped by html/template, and the source linked only when
// PublicSourceURL allows it, checked again here whatever was stored.
func RenderPage(w io.Writer, p Page) error {
	src := p.Link.Preview.Source
	return pageTemplate.Execute(w, pageView{
		ID:         p.ID,
		Source:     src,
		SourceURL:  PublicSourceURL(src.URL),
		Margins:    p.Link.Preview.Margins,
		Expires:    p.Link.ExpiresAt().UTC().Format("2 January 2006"),
		InstallURL: p.InstallURL,
		Reasons:    ReportReasons,
	})
}

// Notice pages: an expired or unknown link, a switched-off service, and the
// thanks after a report. Same look, one message.
type Notice struct {
	Title, Message, InstallURL string
}

func RenderNotice(w io.Writer, n Notice) error { return noticeTemplate.Execute(w, n) }

const style = `
:root{color-scheme:light dark;--bg:#fbfaf7;--fg:#1d1c1a;--muted:#6b675f;--rule:#e2ded5;--quote:#f1eee7;--accent:#8a5a00}
@media (prefers-color-scheme:dark){:root{--bg:#161513;--fg:#ece9e2;--muted:#a39f96;--rule:#34312c;--quote:#211f1c;--accent:#e0a63a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:640px;margin:0 auto;padding:24px 16px 48px}
h1{font-size:1.4rem;line-height:1.25;margin:0 0 4px}
.muted{color:var(--muted);font-size:.9rem}
a{color:var(--accent)}
.source{margin:0 0 24px}
.margin{border-top:1px solid var(--rule);padding:20px 0}
blockquote{margin:0 0 12px;padding:10px 14px;background:var(--quote);border-left:3px solid var(--rule);font-family:Georgia,serif;font-size:.95rem;overflow-wrap:anywhere}
.here{color:var(--accent);font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-weight:600;white-space:nowrap}
.text{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
.install{display:block;text-align:center;padding:14px;margin:24px 0;border-radius:12px;background:var(--accent);color:var(--bg);font-weight:600;text-decoration:none}
details{margin-top:32px;border-top:1px solid var(--rule);padding-top:16px}
summary{cursor:pointer;color:var(--muted)}
label{display:block;padding:6px 0}
button{font:inherit;padding:10px 16px;margin-top:8px;border-radius:10px;border:1px solid var(--rule);background:var(--quote);color:var(--fg)}
`

var pageTemplate = template.Must(template.New("page").Funcs(template.FuncMap{
	"trim": strings.TrimSpace,
}).Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>Margins on {{.Source.Title}}</title>
<style>` + style + `</style>
</head>
<body>
<main>
<header class="source">
<p class="muted">Margins shared with Spoken Margins on</p>
<h1>{{if .SourceURL}}<a href="{{.SourceURL}}" rel="noopener noreferrer">{{.Source.Title}}</a>{{else}}{{.Source.Title}}{{end}}</h1>
{{if .Source.Show}}<p class="muted">{{.Source.Show}}</p>{{end}}
</header>
{{range .Margins}}<section class="margin">
{{if or (trim .Before) (trim .After)}}<blockquote>{{if trim .Before}}…{{.Before}} {{end}}<span class="here" aria-label="Margin here">◆ Margin</span>{{if trim .After}} {{.After}}…{{end}}
<br><span class="muted">Quoted from <cite>{{$.Source.Title}}</cite>{{if $.Source.Show}}, {{$.Source.Show}}{{end}}</span></blockquote>{{end}}
{{if trim .Text}}<p class="text">{{.Text}}</p>{{else}}<p class="text muted">A spoken Margin. Open it in Spoken Margins to hear it.</p>{{end}}
</section>
{{end}}<a class="install" href="{{.InstallURL}}">Get Spoken Margins to hear these at their place in the source</a>
<p class="muted">This link stops working on {{.Expires}}.</p>
<details>
<summary>Report this link</summary>
<form method="post" action="/l/{{.ID}}/report">
{{range $i, $r := .Reasons}}<label><input type="radio" name="reason" value="{{$r.Value}}"{{if eq $i 0}} checked{{end}}> {{$r.Label}}</label>
{{end}}<button type="submit">Send report</button>
</form>
</details>
</main>
</body>
</html>
`))

var noticeTemplate = template.Must(template.New("notice").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>{{.Title}}</title>
<style>` + style + `</style>
</head>
<body>
<main>
<h1>{{.Title}}</h1>
<p>{{.Message}}</p>
{{if .InstallURL}}<a class="install" href="{{.InstallURL}}">Get Spoken Margins</a>{{end}}
</main>
</body>
</html>
`))
